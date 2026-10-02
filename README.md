# retail-shed — SUSE Edge retail lab on vrack0

A retail estate in miniature, built on what worked in `hypothetical-K8S-environment`
(demo-shed). **HQ** is a 3-node HA Rancher Prime with no load-balancer VMs: its VIP
is held inside the cluster by MetalLB and Endpoint Copier Operator, the SUSE Edge pattern. **Stores** are K3s clusters on SL Micro 6.2 boxes that are "shipped"
with one generic image and **enrol themselves** at first boot. Each store sits on
its own isolated LAN behind a simulated WAN link.

## Topology

![retail-shed topology: HQ Rancher with an in-cluster MetalLB VIP, six isolated store networks behind NAT, Liverpool on the HQ LAN with an iPhone opening its till](docs/retail-shed.svg)

The same drawing, with the enrolment steps and what Fleet gives each store, is in
[`docs/retail-shed.html`](docs/retail-shed.html). After editing that page, run
`python3 docs/export-svg.py` to regenerate the image above.

| Role | Hosts | Image | vCPU / RAM / disk | Network |
|---|---|---|---|---|
| Rancher Prime (RKE2 `local`) | retail-rancher01..03 | `rancher/retail-rancher.iso` | 4 / 16 GB / 64 GB | br0, DHCP |
| Store box | store-`<store>`-n`<N>` | `store/retail-store.iso` (one image for all) | 4 / 8 GB / 64 GB | rtl-`<store>`, fixed 10.120.`<net>`.1`<N>` |

`stores.txt` lists the stores (region, tier, LAN number); `nodes.txt` lists every VM
with its MAC and network. HQ addresses come from DHCP; `discover-ips.sh` writes them
to `hosts.txt`. Store addresses are fixed by the store router's DHCP reservations.

| Store | Region | Tier | Nodes | LAN |
|---|---|---|---|---|
| lon-001 | london | flagship | 3 (HA etcd) | 10.120.1.0/24 |
| lon-002 | london | standard | 1 | 10.120.2.0/24 |
| man-001 | manchester | standard | 1 | 10.120.3.0/24 |
| edi-001 | edinburgh | standard | 1 | 10.120.4.0/24 |
| bri-001 | bristol | standard | 1 | 10.120.5.0/24 |
| gla-001 | glasgow | kiosk (SLES 16 + GNOME) | 1 | 10.120.6.0/24 |
| liv-001 | liverpool | standard | 1 | HQ LAN `br0` (DHCP) |

## How a store box onboards

1. **HQ creates the store record.** `setup-stores.sh` makes an empty K3s custom cluster
   `store-<store>` in Rancher, labelled `retail.lab/store`, `retail.lab/region` and
   `retail.lab/tier`. These are the labels Fleet will target.
2. **The box is generic.** Every store box boots the same `retail-store.iso`. The box's
   identity is its SMBIOS serial (`store-man-001-n1`), which `create-vms.sh` sets to the VM name.
   On real hardware it would be the chassis serial mapped in an asset database.
3. **First boot.** `retail-enrol.service` (from `eib/store/custom/files`):
   - names the host after its serial;
   - waits for HQ's `store-<store>` cluster;
   - reads that cluster's registration command and runs it with all roles plus the label
     `retail.lab/store`. If the record doesn't exist yet, or the WAN is down, it keeps retrying.
4. **Verified, not insecure.** `make-pki.sh` creates an HQ CA that signs Rancher's
   certificate. Rancher runs with `privateCA: true`, and the store image trusts the CA. So
   boxes use Rancher's verified registration command with a CA checksum, unlike demo-shed's
   `--insecure` one.
5. **Enrolment credential.** The image holds a Rancher API token for the user `store-enrol`. Its
   global role can only `get/list` provisioning clusters and cluster registration tokens.
   Anyone who extracts it from an image can enrol a rogue node into a store cluster, which is
   acceptable for a lab. In production, use Elemental with TPM attestation, or a short-lived
   per-batch token.

## HQ VIP without load balancers

`setup-rancher.sh` follows the SUSE Edge HA control-plane pattern:

1. retail-rancher01 starts RKE2 alone. Its `tls-san` already includes the VIP and the Rancher name.
2. The SUSE Edge charts **MetalLB** (`307.0.3+up0.16.1`) and **Endpoint Copier Operator**
   (`307.0.1+up0.3.0`) are installed from `oci://registry.suse.com/edge/charts`.
3. MetalLB gets a one-address pool `hq-vip` (`172.16.0.251/32`, `autoAssign: false`) and
   announces it in L2 mode on `enp1s0`. Services ask for the VIP by annotation.
4. The `default/kubernetes-vip` service (LoadBalancer, 6443 + 9345) has no selector. ECO copies
   the `kubernetes` service's endpoints into it, so the VIP always reaches every live apiserver
   and RKE2 supervisor.
5. retail-rancher02/03 join through `https://172.16.0.251:9345`.
6. The RKE2 ingress controller's service becomes a LoadBalancer on the **same** IP
   (`metallb.io/allow-shared-ip: retail-hq-vip`), so ports 80 and 443 for Rancher are on the VIP too.

If the node announcing the VIP dies, MetalLB moves the announcement to another node within
seconds (gratuitous ARP). Kubernetes services don't answer ping on a LoadBalancer IP, so check
the VIP with `curl -k https://172.16.0.251:6443/`, not `ping`.

## Store networks and the WAN

- Each store is a libvirt NAT network (`create-networks.sh`) on bridge `rtl-<store>`.
  libvirt's dnsmasq at `.1` is the store router:
  - it gives out fixed addresses by MAC;
  - it answers `rancher.retail-shed.local` with the HQ VIP, so store nodes and their CoreDNS
    need no hosts-file tricks.
- Store traffic leaves through NAT on vrack0. Stores can reach HQ but not each other, and
  nothing can connect into a store. That's fine, because Rancher and Fleet agents only dial out.
- To reach a store node, jump through vrack0: `ssh -J root@172.16.0.69 root@10.120.3.11`.
- `wan.sh` shapes the HQ→store direction on the store bridge. That direction carries every
  reply a store gets, so it affects round trips. Traffic inside the store LAN and the
  router's ARP/DHCP/DNS are never shaped, so a WAN outage leaves the store LAN running.

```bash
./wan.sh status
./wan.sh degrade man-001 120 1 10mbit   # 120 ms (±12), 1 % loss, 10 Mbit/s
./wan.sh outage edi-001                  # store disconnected from HQ
./wan.sh restore all
```

## Build order

```bash
# 0. Secrets (same format as demo-shed): eib/secrets.env holds the SCC code + root hash
./make-pki.sh                    # HQ CA + Rancher certificate in pki/ (once)
./fetch-rpms.sh                  # pinned, signature-checked RKE2 / k3s-selinux RPMs
./render-eib.sh rancher
./build-images.sh rancher        # rsync eib/rancher to vrack0, EIB builds the ISO there

# 1. HQ
./create-vms.sh rancher
./discover-ips.sh                # once all 3 answer on br0 → hosts.txt
./setup-rancher.sh               # RKE2 ×3, MetalLB/ECO VIP, cert-manager, Rancher

# 2. Store image (needs Rancher: the enrolment token is baked in)
./setup-stores.sh --enrol-only   # store-enrol role/user/token → credentials.env
./render-eib.sh store
./build-images.sh store

# 3. Stores
./create-networks.sh             # rtl-<store> networks (done before step 1 is fine)
./setup-stores.sh                # store records in Rancher
./create-vms.sh store            # boxes install, boot, enrol themselves
```

Day 2:

- `./shutdown-platform.sh` takes an etcd snapshot, then powers off the stores, then Rancher.
- `./startup-platform.sh` powers on in the reverse order.
- `./cleanup-platform.sh [rancher|store|networks|<store>]` deletes VMs and their disks. When
  stores are removed but Rancher is kept, their clusters are deleted in Rancher too; run
  `setup-stores.sh` before re-creating them.
- To add a store, add a line to `stores.txt` and its nodes to `nodes.txt`, then run
  `create-networks.sh`, `setup-stores.sh <store>` and `create-vms.sh <node>`.
  The image needs no rebuild.

## Access

- UI: https://rancher.retail-shed.local, user `admin`, password
  `RANCHER_BOOTSTRAP_PASSWORD` in `credentials.env` (gitignored)
- The workstation needs `172.16.0.251 rancher.retail-shed.local` in `/etc/hosts`. To skip
  browser warnings, trust `pki/ca.pem`.
- Rancher cluster kubeconfig: `/etc/rancher/rke2/rke2.yaml` on retail-rancher01

## Versions

- SL Micro 6.2 (Default self-install ISO) built with Edge Image Builder 1.3.1
- HQ: RKE2 v1.35.8+rke2r1 (side-loaded RPMs), Rancher Prime 2.15.2, cert-manager v1.21.2,
  MetalLB 0.16.1 and Endpoint Copier Operator 0.3.0 (SUSE Edge 3.7 charts)
- Stores: the newest K3s v1.35 that Rancher offers (`setup-stores.sh`; override with `K3S_VERSION`),
  `k3s-selinux` 1.6 side-loaded into the image

## Notes and gotchas (carried over from demo-shed / hf-shed)

- **Side-loaded RPMs, not rpm.rancher.io repos.** `fetch-rpms.sh` downloads the RPMs, and EIB
  checks each one against `rpms/gpg-keys`. There are two reasons:
  - The K3s SL Micro repo has unsigned metadata.
  - On 2026-10-01, Cloudflare served a stale cached `repomd.xml` for the RKE2 1.35 repo next
    to the fresh signature for v1.35.9, so EIB refused the repo with "Signature verification
    failed".
- **Where combustion can write.** On SL Micro, `/usr/local`, `/opt`, `/var` and `/home` are
  separate subvolumes mounted over the snapshot that combustion writes. Anything a custom script
  puts there is hidden after boot. Use `/usr/libexec` or `/etc`, and create parent directories
  (`install -D`).
  When any combustion script fails, the box stops at "Press Enter for system maintenance
  (or press Control-D to continue)". To see why, type `journalctl -u combustion` in that
  emergency shell. The serial console works: `virsh console <vm>` on vrack0.
- **Agent install races D-Bus on first boot.** On one box, the agent installer ran
  `systemctl` before the system bus was up. It only logged "Failed to connect to system scope
  bus" and left `rancher-system-agent` disabled, so the box never finished joining. The
  enrolment service now starts after `dbus.service`, enables the agent itself, and marks the
  box enrolled only when the agent is running.
- **One EIB directory per image** (`eib/rancher`, `eib/store`). EIB installs every RPM in a
  directory's `rpms/` into every image built from that directory.
- **Self-installer.** The SL Micro self-installer never powers off; it installs and boots into
  the OS. `create-vms.sh` then removes the ISO from the saved VM config and sets
  `on_reboot=restart`. That config takes effect at the VM's next cold boot.
- **SELinux** is enforcing everywhere.
- **No DNS zone on the HQ LAN.** HQ nodes get `rancher.retail-shed.local` from `/etc/hosts`
  (EIB script `02-hosts.sh`). Store nodes get it from their store router.
- **Images and the enrolment token.** Rebuilding Rancher invalidates the enrolment token, so
  the store image must be re-rendered and rebuilt after a Rancher rebuild.
- **Coexistence.** demo-shed and hf-shed are not running. retail-shed uses VIP .251, so it can
  coexist with demo-shed (.252) on br0.

## Store on the HQ LAN (Liverpool)

`liv-001` has `lan` instead of a network number in `stores.txt`. Its box sits on `br0`
(`172.16.0.0/16`) next to the Rancher nodes and gets its address from the LAN's DHCP.
`discover-ips.sh` records that address in `hosts.txt`. Liverpool uses the same SL Micro store
image as the other stores. The differences come from having no store router:

- **Rancher name on the box.** The LAN DNS has no `retail-shed.local` zone. If
  `rancher.retail-shed.local` doesn't resolve, `retail-enrol` adds it to `/etc/hosts`,
  pointing at `RANCHER_VIP` from `enrol.env`.
- **Rancher name in pods.** `setup-stores.sh` gives every new store cluster a
  `kube-system/coredns-custom` ConfigMap (through Rancher's `additionalManifest`) with a
  `retail-shed.local` zone. K3s's CoreDNS imports it, so `cattle-cluster-agent` and
  `fleet-agent` resolve the name on any network.
- **No WAN simulation and no isolation.** There is no store bridge to shape, so `wan.sh`,
  `create-networks.sh` and `cleanup-platform.sh networks` skip `lan` stores. The box can
  reach, and be reached by, everything on the HQ LAN.

## Kiosk store (Glasgow)

`gla-001` (tier `kiosk`) is a store whose box has a screen. It runs **SLES 16 with GNOME**
instead of SL Micro. The till opens full-screen in Firefox on that screen, while the box
runs K3s and enrols like any other store.

- **Install:** Agama installs unattended from `SLES-16.0-Full-x86_64-QU0.install.iso`
  (on vrack0 in `/var/lib/libvirt/images/`), offline and without SCC registration.
  `render-kiosk.sh` builds the profile `agama/kiosk/retail-kiosk.json`. `create-vms.sh` serves
  it on `http://10.120.6.1:8099` (Glasgow's LAN only) for the length of the install and boots
  the installer with `inst.auto=…`.
- **Same enrolment.** The profile's post-install script unpacks the same `retail-enrol`
  service, token and HQ CA as the store image, adds `k3s-selinux` and switches firewalld off
  (the store LAN is already isolated).
- **Kiosk session:**
  - GDM logs the `kiosk` user in automatically.
  - The GNOME autostart entry `retail-kiosk-launcher` shows a holding page until the box's
    till answers on `/healthz`, then keeps `firefox --kiosk http://<box IP>/` open and
    restarts it if it closes.
  - dconf locks out screen blanking and the lock screen; Firefox policies turn off
    first-run pages.
- **Watching the screen:** the VM has a virtio GPU and a USB tablet. On vrack0, run
  `virsh vncdisplay store-gla-001-n1`, then tunnel that port with `ssh -L`.
- **Limits:** the SLES media has no `gnome-kiosk`, Chromium or `cage`, so this is full GNOME
  with a kiosk browser rather than a locked single-app shell; keyboard shortcuts still work.
- **Gotcha: Agama patterns.** Give `software.patterns` as `{"add": [...]}`. A plain list replaces
  the product's default patterns. The first build used `["gnome"]`, which dropped the `selinux`
  pattern, and the box booted with `security=` (empty) on the kernel command line, so SELinux
  was off despite `SELINUX=enforcing` in `/etc/selinux/config`.

```bash
./create-networks.sh && ./setup-stores.sh gla-001
./render-kiosk.sh
./create-vms.sh store-gla-001-n1     # waits for the Agama install (~15-20 min)
```

## Store app (Fleet)

[smclab0/retail-shed-fleet](https://github.com/smclab0/retail-shed-fleet) holds **store-pos**:
a till app with a click & collect board for flagship stores. GitHub Actions builds
`ghcr.io/smclab0/store-pos`, and the Fleet bundle in that repo deploys it to every store.

- **One bundle for every store.** Fleet fills each store's identity from its cluster labels.
  London stores get a 1.12 price multiplier, and only `tier=flagship` gets `/collect/`.
- **Register it once** on the Rancher cluster: `kubectl apply -f fleet/gitrepo.yaml` (from that
  repo). Fleet polls `main` every 30 s.
- **Open a till** from a workstation: `ssh -L 8080:10.120.3.11:80 root@172.16.0.69`, then
  browse to http://localhost:8080/.
- **Offline trading.** With `./wan.sh outage man-001`, the till shows "HQ offline - trading
  locally" and keeps selling. Sales made offline are counted.

The diagram of the whole estate is in [`docs/retail-shed.html`](docs/retail-shed.html).
