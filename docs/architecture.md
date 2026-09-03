# Architecture — lumen-platform

## Scope of this milestone

Stand up a 3-node k3s cluster (1 control-plane, 2 workers) on Ubuntu
Server ARM64 VMs running under UTM on an Apple M1 MacBook Pro, configured
idempotently via Ansible and operated through a Makefile. **No
application or platform workloads are deployed** — the milestone is
complete when all three nodes report `Ready`.

A second, optional milestone layers ArgoCD on top of this cluster once
it's `Ready`, and hands it PostgreSQL + Metabase to manage — see
["GitOps (ArgoCD)"](#gitops-argocd) below. ArgoCD itself is bootstrapped
through this same Ansible/Makefile interface (a deliberate choice for
now, rather than a separate repo/tool: simpler for a single operator
running one or two apps), but once bootstrapped, changing
PostgreSQL/Metabase config is a `git push`, not a Makefile target — see
that section for how the two interact. If more apps get deployed onto
this cluster later, split workload deployment out into its own
repo/tool at that point — infra and workload lifecycles diverge enough
at that scale to be worth the separation.

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

## GitOps (ArgoCD)

`ansible/playbooks/platform.yml` (`make platform`) deploys an optional
second layer on top of the Ready cluster: ArgoCD, bootstrapped with
just enough to hand ongoing management of PostgreSQL + Metabase to
ArgoCD itself. Ansible's job stops there — it does **not** deploy
PostgreSQL or Metabase directly (it used to, via dedicated
`kubernetes.core.helm` Ansible roles; that logic now lives as plain
committed YAML under `argocd/`, reconciled by ArgoCD instead).

### Layout

```
argocd/
  bootstrap/
    project.yaml     # AppProject "platform" - scopes allowed chart repos + destinations
    root.yaml         # Application "root" (the only thing Ansible applies directly)
  apps/
    postgres-operator.yaml   # cnpg/cloudnative-pg chart -> cnpg-system
    postgres-cluster.yaml    # cnpg/cluster chart -> data-platform (database "metabase")
    metabase.yaml             # pmint93/metabase chart -> data-platform
```

`ansible/roles/argocd` installs ArgoCD via its official Helm chart, then
applies `argocd/bootstrap/project.yaml` and `argocd/bootstrap/root.yaml`
with `k3s kubectl apply -f` (once each, idempotent). `root.yaml` is an
["app of apps"](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
Application pointed at `argocd/apps/` in this same repo; ArgoCD
discovers the three child Applications there on its own — Ansible never
touches them directly.

| Namespace       | What                                                                                                                                                                     |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `argocd`        | ArgoCD itself                                                                                                                                                            |
| `cnpg-system`   | [CloudNativePG](https://cloudnative-pg.io) operator (cluster-wide), as the `postgres-operator` Application                                                              |
| `data-platform` | A single-instance CloudNativePG `Cluster` (database `metabase`, `local-path` storage) as `postgres-cluster`, and Metabase as `metabase`, configured to use that Cluster as its application database |

**Changed workflow:** to bump a chart version or change a value for
PostgreSQL or Metabase, edit the corresponding file under `argocd/apps/`
and `git push` — ArgoCD picks it up on its next poll (~3 min by
default) or immediately via `argocd app sync <name>` / the UI.
`make platform` is no longer how you change these two; it's only how
you (re)install ArgoCD itself.

**Sync policy:** all four Applications (`root` + the three children) use
`syncPolicy.automated: {selfHeal: true, prune: true}` — ArgoCD both
auto-applies git changes and reverts drift, including manual `kubectl
edit`/`helm upgrade` against these resources. This is fully hands-off
GitOps by design; if you need to make a one-off manual change, either
commit it or expect ArgoCD to revert it within one reconcile cycle.

**Ordering:** ArgoCD has no built-in health check for
`clusters.postgresql.cnpg.io` Custom Resources, so it does not block
syncing `metabase.yaml` until `postgres-cluster.yaml` reports healthy
the way `ansible/roles/postgres` used to (`k3s kubectl wait
--for=condition=Ready`). In practice this is harmless — the Metabase
pod crash-loops until the CNPG-generated Secret exists, then
self-heals — but it's worth knowing if `metabase` shows `Progressing`
right after bootstrap. A custom Lua health check
(`configs.resource.customizations` in the ArgoCD Helm values) would
close this gap; left as a future enhancement, not needed for a
solo-operator edge lab.

**Why CloudNativePG, not the more commonly-referenced Bitnami
`postgresql` chart:** Bitnami moved its Helm-chart images behind a
paywall/legacy-archive on 2025-08-28, making `bitnami/postgresql` a
poor default going forward. CloudNativePG is a free, actively
maintained, CNCF-adjacent Postgres operator, and its operational model
(Kubernetes-native `Cluster` custom resource, self-managed credential
Secret) fits this repo's existing patterns better than a bare
StatefulSet chart would.

**Metabase image:** Metabase's upstream image (`metabase/metabase`) is
a standard multi-arch image, so ArgoCD/Helm pull it straight from
Docker Hub on every node — no custom image build/distribute step, and
no Docker dependency on the control machine (unlike the old
Dagster-based layer this replaced).

**Database wiring:** `metabase.yaml`'s inline Helm values point
`database.existingSecret` directly at the CNPG-generated
`platform-postgres-cluster-app` Secret instead of threading the
password through Ansible or ArgoCD — the Metabase pod reads its own
credentials from that Secret at startup, so neither Ansible nor ArgoCD
ever sees the database password. See "Secrets handling" below.

**Ingress:** ArgoCD itself is exposed via a Traefik `Ingress` at
`argocd_ingress_host` (default `argocd.lumen.local`,
`ansible/inventory/group_vars/platform.yml`), served over plain HTTP
(`configs.params."server.insecure": true`) since nothing else in this
cluster uses TLS either. Metabase is exposed the same way at
`metabase.lumen.local` (a literal in `argocd/apps/metabase.yaml`, no
longer an Ansible variable). Traefik/ServiceLB run a pod on every node
and bind host ports 80/443, so any cluster node's IP resolves either
host — `make platform` prints the exact `/etc/hosts` line for ArgoCD.

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
  `platform-postgres-cluster-app` inside the `data-platform` namespace —
  neither Ansible nor ArgoCD ever invents, stores, or reads this
  password. `argocd/apps/metabase.yaml` points the Metabase Helm release
  at that Secret directly (`database.existingSecret`), so the Metabase
  pod reads its own credentials from Kubernetes at startup. To read it
  yourself: `kubectl -n data-platform get secret
  platform-postgres-cluster-app -o jsonpath='{.data.password}' | base64
  -d`.
- **ArgoCD's own initial admin password** is auto-generated by the
  `argo-cd` Helm chart into the `argocd-initial-admin-secret` Secret in
  the `argocd` namespace — same treatment, Ansible never reads it.
  `make platform` prints the retrieval command.

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
