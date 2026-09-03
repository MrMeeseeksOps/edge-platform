# Prerequisites — lumen-platform

Complete these steps before running anything in `Makefile`.

## 1. macOS host

- Apple M1 MacBook Pro, macOS with virtualization enabled (default).
- [UTM](https://mac.getutm.app/) installed (Mac App Store or direct
  download).
- Enough free resources for three VMs running concurrently. As a
  starting point: 2 vCPU / 4 GB RAM / 32 GB disk per VM (control-plane
  can be slightly larger, e.g. 4 GB–6 GB RAM, if you plan to add
  workloads after this milestone).

## 2. Create the three VMs in UTM

For each of `lumen-cp-01`, `lumen-worker-01`, `lumen-worker-02`:

1. Download the **Ubuntu Server for ARM64** ISO (or use the ARM64 cloud
   image if you prefer cloud-init provisioning).
2. In UTM: **New VM → Virtualize → Linux**, attach the ISO, allocate
   CPU/RAM/disk per above.
3. Network: set the VM to **Bridged** (recommended — the VM joins your
   physical LAN directly via the LAN's own DHCP, and is reachable from
   any machine on that LAN, not just the Mac host, for SSH/kubectl) or
   **Shared Network** if you'd rather NAT behind the Mac host and only
   the Mac itself needs to reach the VMs. Avoid "Emulated VLAN" isolated
   modes that block host↔VM traffic.
4. During Ubuntu Server install: set the hostname to match the node
   (`lumen-cp-01`, etc.), create an admin user, and **enable OpenSSH
   server** when prompted.
5. After first boot, note the IP address each VM receives (`ip a`), and
   update `ansible/inventory/hosts.ini` with the actual addresses.

## 3. SSH access (no secrets committed)

1. On your control machine (the Mac, or wherever you'll run Ansible
   from), generate a key pair if you don't already have one:

   ```bash
   ssh-keygen -t ed25519 -C "lumen-platform"
   ```

2. Copy the **public** key to each VM:

   ```bash
   ssh-copy-id ubuntu@192.168.1.120   # lumen-cp-01
   ssh-copy-id ubuntu@192.168.1.121   # lumen-worker-01
   ssh-copy-id ubuntu@192.168.1.122   # lumen-worker-02
   ```

   (These IPs assume Bridged networking on a `192.168.1.0/24` LAN, as in
   `ansible/inventory/hosts.ini` — substitute your VMs' actual addresses.)

3. Confirm you can log in without a password prompt:

   ```bash
   ssh ubuntu@192.168.1.120
   ```

The private key never leaves your control machine and is never
referenced by path inside this repository — Ansible uses your normal SSH
agent/config.

## 4. Sudo access on the VMs

The `ansible_user` (default `ubuntu`, set in
`ansible/inventory/hosts.ini`) needs to be able to `sudo` on each VM.

- If installed from the Ubuntu Server **ISO**, the created user usually
  needs a sudo password. In that case, run Make targets with
  `ASK_PASS=1`, e.g. `make cluster ASK_PASS=1` — Ansible will prompt once
  per run.
- If provisioned via **cloud-init** with passwordless sudo configured,
  no flag is needed.

## 5. Control machine tooling

On whichever machine will run `make` (this can be the Mac host itself):

- **Ansible** ≥ 2.14 (`brew install ansible` on macOS, or `pipx install
  ansible`).
- **Python 3** (for Ansible itself and the `keyscan` Make target).
- **kubectl**, matching the k3s Kubernetes minor version where possible
  (`brew install kubectl`) — needed for `make status` and any manual
  cluster inspection after `make kubeconfig`.
- Run `make install-deps` once to pull the required Ansible collections
  (`community.general`, `ansible.posix`, and — if you'll run the
  optional platform layer, `make platform` — `kubernetes.core`, which
  provides the Helm-related modules).

## 6. Trust the VMs' SSH host keys

Run `make keyscan` once after the VMs are up (and again if you ever
rebuild a VM) to add their host keys to `~/.ssh/known_hosts`, so Ansible
runs don't hang on an interactive host-key prompt. This repo does **not**
disable host-key checking — you're expected to review and accept keys
explicitly.

## 7. Verify before proceeding

```bash
make ping
```

This runs `ansible/playbooks/preflight.yml`, confirming SSH connectivity,
sudo access, and that each node is Ubuntu on arm64. Fix anything it
reports before running `make cluster`.

## 8. Platform layer (optional)

Once `make healthcheck` passes, `make platform` deploys PostgreSQL +
Metabase (see
[docs/architecture.md](architecture.md#platform-workloads)). Helm
itself is installed automatically onto the control-plane node, the same
way k3s is, and Metabase's image is pulled directly from Docker Hub on
each node — no extra tooling is required on the control machine beyond
what's already listed in step 5. After `make platform` finishes, add
the `/etc/hosts` line it prints (mapping `metabase_ingress_host` to a
node IP) to reach the Metabase UI in a browser.
