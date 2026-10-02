#!/bin/bash
# Create and install retail-shed VMs on vrack0 from nodes.txt.
# Usage: ./create-vms.sh [--dry-run] [role|store-name...]
#   roles: rancher store kiosk (default: all); or name VMs, e.g. store-man-001-n1
#
# Store VMs carry their identity in the SMBIOS serial (= VM name), which is what
# the generic store image reads at first boot to enrol itself.
# The SL Micro self-installer never powers off: it installs and boots the OS.
# The saved config is then switched to no ISO and on_reboot=restart, which the
# VM picks up at its next cold boot (startup-platform.sh / virsh start).
#
# Kiosk boxes install SLES 16 (GNOME) with Agama instead: the installer boots
# from the SLES ISO and fetches its profile (render-kiosk.sh) from a temporary
# HTTP server on the store router's address, reachable only from that store's
# LAN, which stops when the install finishes. virt-install waits for the
# install, so kiosk boxes are created one at a time.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DRY_RUN=false SEL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) SEL+=("$arg") ;;
  esac
done
[ ${#SEL[@]} -gt 0 ] || SEL=(rancher store kiosk)
SLES_ISO=/var/lib/libvirt/images/SLES-16.0-Full-x86_64-QU0.install.iso
PROFILE_PORT=8099

# Not a pipe: kiosk installs run ssh and background jobs that must not eat stdin
while read -r name mac role network; do
  [[ " ${SEL[*]} " == *" ${role} "* || " ${SEL[*]} " == *" ${name} "* ]] || continue
  case "$role" in
    rancher) vcpus=4 mem=16384 disk=64 iso=rancher/retail-rancher.iso ;;
    store) vcpus=4 mem=8192 disk=64 iso=store/retail-store.iso ;;
    kiosk) vcpus=4 mem=8192 disk=64 ;;
  esac
  if [ "$network" = br0 ]; then nic="bridge=br0"; else nic="network=${network}"; fi
  if [ "$role" = kiosk ]; then
    gw="${STORE_NET_PREFIX}.$(awk -v n="$network" '"rtl-" $1 == n { print $4 }' "${DIR}/stores.txt").1"
    cmd="virt-install --name ${name} --vcpus ${vcpus} --memory ${mem} --cpu host-passthrough \
      --os-variant sles16 --virt-type kvm \
      --boot loader=/usr/share/qemu/ovmf-x86_64-4m-code.bin,loader.readonly=on,loader.secure=off,loader.type=pflash \
      --sysinfo system.serial=${name} \
      --disk path=${HV_DISKS}/${name}.qcow2,bus=scsi,size=${disk},format=qcow2 \
      --graphics vnc,listen=127.0.0.1,port=-1 --video virtio --input tablet,bus=usb \
      --serial pty --console pty,target_type=serial --rng random \
      --tpm emulator,model=tpm-crb,version=2.0 \
      --network ${nic},model=virtio,mac=${mac} \
      --location ${SLES_ISO},kernel=boot/x86_64/loader/linux,initrd=boot/x86_64/loader/initrd \
      --extra-args 'inst.auto=http://${gw}:${PROFILE_PORT}/retail-kiosk.json inst.finish=reboot console=tty0 console=ttyS0,115200' \
      --noautoconsole --wait -1"
  else
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
  fi
  if $DRY_RUN; then
    echo "$cmd" | tr -s ' '
    continue
  fi
  if $SSH "$HYPERVISOR" "virsh dominfo ${name}" &>/dev/null; then
    echo "==> Skipping ${name}: VM already exists"
    continue
  fi
  echo "==> Creating ${name} (${role}, ${mac}, ${network})"
  if [ "$role" = kiosk ]; then
    [ -f "${DIR}/agama/kiosk/retail-kiosk.json" ] || { echo "ERROR: run ./render-kiosk.sh first" >&2; exit 1; }
    srv="${HV_BASE}/agama/${name}"
    ssh -o BatchMode=yes "$HYPERVISOR" "umask 077; mkdir -p ${srv} && cat > ${srv}/retail-kiosk.json" \
      <"${DIR}/agama/kiosk/retail-kiosk.json"
    $SSH "$HYPERVISOR" "nohup python3 -m http.server ${PROFILE_PORT} --bind ${gw} --directory ${srv} \
      >${srv}/http.log 2>&1 & echo \$! > ${srv}/http.pid"
    echo "    Agama installing SLES 16 + GNOME (profile on http://${gw}:${PROFILE_PORT}); this takes a while"
    rc=0
    $SSH "$HYPERVISOR" "$cmd" >/dev/null || rc=$?
    $SSH "$HYPERVISOR" "kill \$(cat ${srv}/http.pid) 2>/dev/null; rm -rf ${srv}"
    [ $rc -eq 0 ] || { echo "ERROR: ${name} install failed (virsh console ${name} on vrack0)" >&2; exit 1; }
  else
    $SSH "$HYPERVISOR" "$cmd" >/dev/null
  fi
done < <(grep -v '^#' "${DIR}/nodes.txt")
