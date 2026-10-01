#!/bin/bash
# Create and install retail-shed VMs on vrack0 from nodes.txt.
# Usage: ./create-vms.sh [--dry-run] [role|store-name...]
#   roles: rancher store (default: all); or name VMs, e.g. store-man-001-n1
#
# Store VMs carry their identity in the SMBIOS serial (= VM name), which is what
# the generic store image reads at first boot to enrol itself.
# The SL Micro self-installer never powers off: it installs and boots the OS.
# The saved config is then switched to no ISO and on_reboot=restart, which the
# VM picks up at its next cold boot (startup-platform.sh / virsh start).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DRY_RUN=false SEL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) SEL+=("$arg") ;;
  esac
done
[ ${#SEL[@]} -gt 0 ] || SEL=(rancher store)

grep -v '^#' "${DIR}/nodes.txt" | while read -r name mac role network; do
  [[ " ${SEL[*]} " == *" ${role} "* || " ${SEL[*]} " == *" ${name} "* ]] || continue
  case "$role" in
    rancher) vcpus=4 mem=16384 disk=64 iso=rancher/retail-rancher.iso ;;
    store) vcpus=4 mem=8192 disk=64 iso=store/retail-store.iso ;;
  esac
  if [ "$network" = br0 ]; then nic="bridge=br0"; else nic="network=${network}"; fi
  cmd="virt-install --name ${name} --vcpus ${vcpus} --memory ${mem} --cpu host-passthrough \
    --os-variant sle15sp6 --virt-type kvm \
    --boot loader=/usr/share/qemu/ovmf-x86_64-4m-code.bin,loader.readonly=on,loader.secure=off,loader.type=pflash \
    --sysinfo system.serial=${name} \
    --disk path=${HV_DISKS}/${name}.qcow2,bus=scsi,size=${disk},format=qcow2 \
    --graphics vnc,listen=127.0.0.1,port=-1 \
    --serial pty --console pty,target_type=serial --rng random \
    --tpm emulator,model=tpm-crb,version=2.0 \
    --network ${nic},model=virtio,mac=${mac} \
    --cdrom ${HV_BASE}/eib/${iso} --noreboot --noautoconsole </dev/null &&
    virt-xml ${name} --edit --events on_reboot=restart &>/dev/null &&
    virt-xml ${name} --remove-device --disk device=cdrom >/dev/null"
  if $DRY_RUN; then
    echo "$cmd" | tr -s ' '
    continue
  fi
  if $SSH "$HYPERVISOR" "virsh dominfo ${name}" &>/dev/null; then
    echo "==> Skipping ${name}: VM already exists"
    continue
  fi
  echo "==> Creating ${name} (${role}, ${mac}, ${network})"
  $SSH "$HYPERVISOR" "$cmd" >/dev/null
done
