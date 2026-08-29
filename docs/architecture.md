# Architecture — lumen-platform

## Scope of this milestone

Stand up a 3-node k3s cluster (1 control-plane, 2 workers) on Ubuntu
Server ARM64 VMs running under UTM on an Apple M1 MacBook Pro, configured
idempotently via Ansible and operated through a Makefile. **No
application or platform workloads are deployed** — the milestone is
complete when all three nodes report `Ready`.

A second, optional milestone layers Dagster + PostgreSQL on top of this
cluster once it's `Ready` — see
["Platform workloads"](#platform-workloads) below. It's deployed
through this same Ansible/Makefile interface as a deliberate choice for
now, rather than a separate repo/GitOps tool: simpler for a single
operator running one or two apps. If more apps get deployed onto this
cluster later, split workload deployment out into its own repo/tool at
that point — infra and workload lifecycles diverge enough at that scale
to be worth the separation.

## Topology

```
                          Apple M1 MacBook Pro (macOS host)
                          ┌───────────────────────────────────────────┐
                          │                                           │
   Engineering            │   UTM (Apple Virtualization / QEMU)      │
   workstation            │                                           │
   (could be this         │   ┌─────────────┐  ┌───────────────┐     │
   same Mac, or a         │   │ lumen-cp-01 │  │lumen-worker-01│     │
   separate machine       │   │  (control-  │  │   (Ubuntu     │     │
   on the same LAN)       │   │   plane)    │  │  Server ARM64)│     │
                          │   │  Ubuntu     │  │               │     │
   ansible / kubectl ─────┼──▶│  Server     │  │  k3s agent    │     │
   over SSH (22) and      │   │  ARM64      │  │               │     │
   the k3s API (6443)     │   │  k3s server │  └───────┬───────┘     │
                          │   └──────┬──────┘          │             │
                          │          │        ┌─────────────────┐   │
                          │          │        │lumen-worker-02  │   │
                          │          │        │ (Ubuntu Server  │   │
                          │          └───────▶│    ARM64)       │   │
                          │      UTM virtual  │  k3s agent      │   │
                          │      network      └─────────────────┘   │
                          │   (Bridged to the physical LAN,          │
                          │    192.168.1.0/24)                       │
                          └───────────────────────────────────────────┘
```

## Node roles

| Node              | Role          | k3s mode | Notes                                  |
|-------------------|---------------|----------|-----------------------------------------|
| `lumen-cp-01`     | control-plane | server   | Runs the API server, etcd (embedded, SQLite backend by default for a single server), scheduler, controller-manager. |
| `lumen-worker-01` | worker        | agent    | Joins `lumen-cp-01` via the cluster join token. |
| `lumen-worker-02` | worker        | agent    | Joins `lumen-cp-01` via the cluster join token. |

Single control-plane node: this milestone does not stand up an HA
(multi-server) control plane. If HA becomes a requirement later, k3s
supports converting to embedded etcd with additional server nodes, but
that is out of scope here.

## Networking

- **UTM network mode**: this deployment uses UTM's **Bridged** mode —
  the VMs join the physical LAN directly and get addresses from the
  LAN's own DHCP (here, `192.168.1.0/24`; see
  `ansible/inventory/hosts.ini` for the actual node IPs). This lets both
  the k3s nodes reach each other and any machine on the LAN — not just
  the Mac host — reach the nodes directly, which satisfies the "remote
  kubectl" requirement. UTM's "Shared Network" mode (NAT with DHCP,
  typically `192.168.64.0/24`, with the Mac host at `192.168.64.1`) also
  works and is simpler if only the Mac host itself needs access; pick
  whichever your network allows and update
  `ansible/inventory/hosts.ini` accordingly.
- **Ports used**:
  - `22/tcp` — SSH, for Ansible configuration management.
  - `6443/tcp` — Kubernetes/k3s API server (control-plane node; also what
    remote `kubectl` talks to).
  - `8472/udp` — flannel VXLAN overlay, between all cluster nodes.
  - `10250/tcp` — kubelet API, between all cluster nodes.
  - `2379/tcp`, `2380/tcp` — reserved for etcd if later converted to HA;
    opened defensively, unused with a single server node today.
  - `80/tcp`, `443/tcp` — Traefik ingress, used by the platform layer
    (see "Platform workloads" below); harmless if you never run
    `make platform`.
- The `common` Ansible role only manages these firewall rules if `ufw` is
  already active on a node; a fresh Ubuntu Server install ships with
  `ufw` inactive by default, so no ports are exposed unless you've
  enabled it yourself.

## Cluster components

k3s bundles several add-ons by default (Traefik ingress, ServiceLB,
local-path-provisioner, CoreDNS, metrics-server). **Traefik and
ServiceLB are enabled** (`ansible/inventory/group_vars/all.yml` →
`k3s_server_disable` is empty) because the platform layer uses Traefik
as its Ingress controller — see "Platform workloads" below. If you only
ever run the infra milestone and want the original minimal footprint,
add `traefik` and `servicelb` back to that list and re-run `make
cluster` — see "Idempotency" below for how that change actually reaches
an already-provisioned node.

## Platform workloads

`ansible/playbooks/platform.yml` (`make platform`) deploys an optional
second layer on top of the Ready cluster: Dagster, backed by
PostgreSQL. It stops at "Dagster is Running and backed by Postgres" —
it does **not** deploy any actual Dagster pipeline/user code (the
chart's `dagster-user-deployments` subchart is disabled); that's future
work, the same way the infra milestone deliberately stops short of
workloads.

| Namespace       | What                                                                                                                                                                     |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `cnpg-system`   | [CloudNativePG](https://cloudnative-pg.io) operator (cluster-wide)                                                                                                      |
| `data-platform` | A single-instance CloudNativePG `Cluster` (database `dagster`, `local-path` storage) + the Dagster Helm release, configured with `postgresql.enabled: false` to use that Cluster instead of its own bundled Postgres |

Both are installed via `kubernetes.core.helm` from the control-plane
node (`ansible/roles/helm`, `ansible/roles/postgres`,
`ansible/roles/dagster`) — the same node `ansible/roles/validate`
already runs `k3s kubectl` from, using the node's local
`/etc/rancher/k3s/k3s.yaml`. No Python `kubernetes` client is required
on any host; `kubernetes.core.helm`/`helm_repository` only shell out to
the `helm` binary.

**Why CloudNativePG, not the more commonly-referenced Bitnami
`postgresql` chart:** Bitnami moved its Helm-chart images behind a
paywall/legacy-archive on 2025-08-28, making `bitnami/postgresql` a
poor default going forward. CloudNativePG is a free, actively
maintained, CNCF-adjacent Postgres operator, and its operational model
(Kubernetes-native `Cluster` custom resource, self-managed credential
Secret) fits this repo's existing patterns better than a bare
StatefulSet chart would.

**Custom ARM64 Dagster image:** the Dagster Helm chart's default image
(`dagster/dagster-celery-k8s`, used for both the webserver and the
daemon regardless of run-launcher choice) is published `linux/amd64`
only — confirmed against Docker Hub, and tracked upstream as still-open
in [dagster-io/dagster#11841](https://github.com/dagster-io/dagster/issues/11841).
Every node in this cluster is ARM64, so `platform.yml` builds a small
custom image instead (`ansible/files/dagster-image/Dockerfile` — just
`pip install dagster dagster-webserver dagster-postgres dagster-k8s` on
a `python:3.11-slim` base, which is essentially what the upstream image
contains for this configuration: no Celery, no bundled user code). The
build runs on the **control machine**, not a cluster node — on the
reference Apple M1 setup that's native ARM64 compilation, no
cross-compilation or emulation needed, and it keeps image builds off
the small edge VMs. The resulting image is saved to a tarball and
imported directly into every node's containerd via `k3s ctr images
import` — it is never pushed to any registry, so the chart's
`pullPolicy`/`imagePullPolicy` are set to `Never` everywhere the image
is referenced (webserver, daemon, and the `K8sRunLauncher`'s job image,
which needs it set explicitly since there's no user-code image to
inherit from with `dagster-user-deployments` disabled). Requires Docker
on the control machine — see `docs/prerequisites.md`.

**Ingress:** the Dagster webserver is exposed via a Traefik `Ingress` at
`dagster_ingress_host` (default `dagster.lumen.local`,
`ansible/inventory/group_vars/platform.yml`). Traefik/ServiceLB run a
pod on every node and bind host ports 80/443, so any cluster node's IP
resolves it — `make platform` prints the exact `/etc/hosts` line to add
on your workstation. `ansible/roles/dagster` overrides the chart's
default Ingress path (`/*`, `pathType: ImplementationSpecific`) to a
standard `path: "/"` / `pathType: Prefix`: the chart's default is
written for nginx-ingress's glob handling, and Traefik treats
`ImplementationSpecific` as a literal path-prefix match — a rule of
`/*` only matches URLs starting with the literal characters `/*`,
never `/` itself, which 404s every real request.

**Storage:** the PostgreSQL `Cluster`'s volume uses k3s's bundled
`local-path-provisioner` (already enabled in the infra milestone), the
same as any other PVC on this cluster. This ties data durability to
whichever node the pod lands on — acceptable for a single-instance edge
lab, not a substitute for backups.

## Secrets handling

No secrets are ever committed to this repository:

- The k3s **cluster join token** is generated by `lumen-cp-01` itself at
  install time. Ansible reads it from
  `/var/lib/rancher/k3s/server/node-token` on the control-plane node and
  holds it only in memory (an Ansible fact) for the duration of the
  `make cluster` run, to pass to the worker nodes. It is never written
  into any file under version control. On each worker it lands only in
  `/etc/rancher/k3s/config.yaml` (mode `0600`, root-owned), and the task
  that renders it (`ansible/roles/k3s_agent/tasks/main.yml`) sets
  `no_log: true` so it never appears in Ansible's console output or logs
  either.
- The **kubeconfig** fetched by `make kubeconfig` is written to
  `output/kubeconfig`, a directory excluded via `.gitignore`. This file
  contains a client certificate that grants full cluster-admin access —
  treat it like a password and do not move it outside `.gitignore`'d
  paths.
- **SSH access** relies on a key pair you generate and manage yourself
  (see `docs/prerequisites.md`) — no private key is ever stored in this
  repository.
- The **PostgreSQL application password** (platform layer) is generated
  and owned entirely by the CloudNativePG operator, in a Secret named
  `<postgres_cluster_name>-cluster-app` inside the `data-platform` namespace —
  Ansible never invents or stores this password. `ansible/roles/postgres`
  reads it once, in-memory, to hand it to the Dagster Helm release
  (`ansible/roles/dagster`); both tasks that touch it are `no_log: true`,
  the same treatment as the k3s join token above. To read it yourself:
  `kubectl -n data-platform get secret platform-postgres-cluster-app -o
  jsonpath='{.data.password}' | base64 -d`.

## Idempotency

Every Ansible task in this repo is written to be safe to re-run:

- Package installation and systemd state use Ansible's native `apt` /
  `systemd` modules, which only change state when needed.
- k3s **package/install state** and k3s **runtime configuration** are
  deliberately kept separate, since coupling them would mean declared
  settings never reach a node that's already been provisioned:
  - The binary and systemd unit are installed once, guarded by a `stat`
    check on `/usr/local/bin/k3s` — the install script only runs when
    the binary is missing.
  - Runtime settings (`k3s_server_disable`, `k3s_cluster_cidr`,
    `k3s_service_cidr`, the `--tls-san` value, and — for workers — the
    join `server`/`token`) are rendered on **every** run to
    `/etc/rancher/k3s/config.yaml`, which k3s reads automatically on
    start. The `template` task only reports "changed" when the
    rendered content actually differs, and that notifies a handler that
    restarts the `k3s` / `k3s-agent` service — so edits to
    `group_vars/all.yml` converge on existing nodes via a plain
    `systemctl restart`, with no reinstall.
  - **"Converged" here describes the config file and the task's
    idempotency — it means the file on disk matches
    `group_vars/all.yml` and the service has been restarted against
    it. It is not automatically a guarantee that every setting inside
    that file has taken effect in the running cluster.** Most settings
    (`disable`, `tls-san`) are re-read and applied by k3s on every
    restart, so file convergence and effective convergence are the
    same thing for them. `cluster-cidr` and `service-cidr` are the
    exception: k3s only consults them at initial datastore bootstrap.
    Changing them in `group_vars/all.yml` still converges the file and
    restarts the service, but k3s will not retroactively re-IP an
    already-running cluster's pods/services — that requires
    re-initializing the datastore, not just a restart.
- `swapoff`, `/etc/fstab`, sysctl, and `/etc/hosts` changes use
  idempotent modules (`replace`, `blockinfile`, `sysctl`) that converge
  rather than append on every run.

This means `make cluster` can be run repeatedly (e.g. after adding a
node, changing `group_vars/all.yml`, or to reconcile drift) without
side effects.

## Validation

`make healthcheck` runs `ansible/playbooks/healthcheck.yml`, which:

1. Confirms exactly 3 nodes are registered with the API server.
2. Asserts none of them report `NotReady`.
3. Confirms all `kube-system` pods are `Running` or `Succeeded`.

This is the authoritative check for "milestone complete." `make status`
provides a human-readable `kubectl get nodes -o wide` view from the
engineering workstation once `make kubeconfig` has been run.
