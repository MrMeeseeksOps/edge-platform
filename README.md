# lumen-platform

k3s bring-up for a 3-node ARM64 cluster running on UTM VMs on an Apple M1
MacBook Pro, configured idempotently via Ansible and operated through a
`Makefile`. The base milestone is **infrastructure bring-up only**: one
control-plane node and two worker nodes with no application/platform
workloads. An additive, optional second layer deploys Dagster +
PostgreSQL on top of that cluster — see
[docs/architecture.md](docs/architecture.md) for scope, topology, and
secrets handling, and [docs/prerequisites.md](docs/prerequisites.md)
before you start.

## Milestones

**Infra — done when:** `make healthcheck` reports all three nodes —
`lumen-cp-01`, `lumen-worker-01`, `lumen-worker-02` — as `Ready`.

**Platform (optional) — done when:** `make platform-healthcheck`
reports the PostgreSQL cluster healthy and the Dagster webserver +
daemon `Available`.

## Repo layout

```
Makefile                          operator interface (see `make help`)
ansible/
  ansible.cfg                     Ansible settings (inventory path, no host-key bypass)
  requirements.yml                required Ansible collections
  inventory/
    hosts.ini                     nodes + IPs — edit this for your VMs
    group_vars/all.yml            non-secret cluster config (k3s version, disabled add-ons, CIDRs)
    group_vars/platform.yml       non-secret platform config (chart versions, namespaces, ingress host)
  files/
    dagster-image/Dockerfile      custom ARM64 Dagster image (upstream image is amd64-only)
  playbooks/
    preflight.yml                 SSH/sudo/OS sanity check
    site.yml                      full bring-up: OS prep -> control-plane -> workers
    fetch-kubeconfig.yml          pulls + localizes kubeconfig for remote kubectl
    healthcheck.yml                validates Ready state (the infra milestone gate)
    platform.yml                  deploys Dagster + PostgreSQL (optional platform layer)
    platform-healthcheck.yml      validates the platform layer (the platform milestone gate)
  roles/
    common/                       OS prep: packages, swap off, sysctl, firewall, hosts file
    k3s_server/                   installs k3s in server mode, exposes join token as a fact
    k3s_agent/                    installs k3s in agent mode, joins the control-plane
    validate/                     node/pod health assertions used by healthcheck.yml
    helm/                         installs Helm CLI + chart repos, on the control-plane node
    postgres/                     deploys the CloudNativePG operator + a PostgreSQL Cluster
    dagster/                      deploys the Dagster Helm chart against that Cluster
    validate_platform/            Dagster/PostgreSQL health assertions used by platform-healthcheck.yml
docs/
  architecture.md                 topology, node roles, networking, secrets handling, idempotency
  prerequisites.md                UTM VM setup, SSH keys, sudo, control-machine tooling
output/                           gitignored — kubeconfig and other generated artifacts land here
```

## Quickstart

```
# 1. Provision 3 Ubuntu Server ARM64 VMs in UTM — see docs/prerequisites.md
# 2. Edit ansible/inventory/hosts.ini with their real IP addresses
make install-deps      # pull required Ansible collections (once)
make keyscan           # trust the VMs' SSH host keys (once per VM)
make ping              # confirm SSH/sudo/OS prerequisites
make cluster           # idempotent: OS prep + k3s control-plane + workers
make kubeconfig        # fetch kubeconfig for remote kubectl access
make status            # kubectl get nodes, from your workstation
make healthcheck       # milestone gate: asserts all nodes Ready
```

Re-running `make cluster` at any point is safe — every task is
idempotent (see [docs/architecture.md](docs/architecture.md#idempotency)).

If your VMs need a sudo password, append `ASK_PASS=1` to any target,
e.g. `make cluster ASK_PASS=1`.

### Platform (optional)

Once the infra milestone is `Ready`, layer Dagster + PostgreSQL on top.
This needs **Docker** on your control machine (see
[docs/prerequisites.md](docs/prerequisites.md#8-platform-layer-optional)) —
`make platform` builds a custom ARM64 Dagster image locally, since the
chart's default image is amd64-only:

```
make platform             # idempotent: image build + Helm + PostgreSQL (CloudNativePG) + Dagster
make platform-healthcheck # milestone gate: asserts PostgreSQL healthy, Dagster Available
```

`make platform` prints the `/etc/hosts` line and URL to reach the
Dagster UI. See
[docs/architecture.md](docs/architecture.md#platform-workloads) for
what gets deployed and why.

## Make targets

Run `make help` for the full list with descriptions.

| Target                | Purpose                                                  |
|------------------------|-----------------------------------------------------------|
| `install-deps`        | Install required Ansible collections                     |
| `keyscan`             | Trust inventory hosts' SSH keys                           |
| `ping`                | Preflight: SSH/sudo/OS checks                             |
| `bootstrap`           | OS prep only (no k3s)                                     |
| `cluster`             | Full idempotent bring-up                                  |
| `kubeconfig`          | Fetch + localize kubeconfig to `output/kubeconfig`        |
| `status`              | `kubectl get nodes -o wide` from the workstation          |
| `healthcheck`         | Infra milestone gate — asserts all nodes Ready             |
| `platform`            | Deploy the platform layer: Dagster + PostgreSQL (idempotent) |
| `platform-healthcheck`| Platform milestone gate — asserts Dagster + PostgreSQL healthy |
| `lint`                | `ansible-lint` if installed                                |
| `clean`               | Remove `output/` (kubeconfig etc.) — does not touch the cluster |

## Secrets

No secrets are committed to this repository. `output/` (kubeconfig), the
cluster join token, and the platform layer's PostgreSQL password —
each written to disk only on the cluster nodes themselves (or held only
in memory, never in this repo) — are the only sensitive artifacts this
repo produces — see
[docs/architecture.md](docs/architecture.md#secrets-handling) for exactly
how each is handled.
