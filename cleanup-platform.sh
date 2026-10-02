#!/bin/bash
# Tear down retail-shed VMs on vrack0 so create-vms.sh can rebuild them:
# power off, undefine, and delete each VM's disk, NVRAM and TPM state.
# The ISOs and EIB files on vrack0 are left alone.
#
# When stores go but Rancher stays, their store-<store> clusters are deleted
# from Rancher too: a rebuilt box must enrol into a fresh cluster, not one that
# still expects the old node's etcd. Run ./setup-stores.sh again before
# re-creating the boxes. Removed HQ VMs are dropped from ~/.ssh/known_hosts.
#
# Usage: ./cleanup-platform.sh [--dry-run] [--yes] [rancher|store|networks|<store>...]
#   default: rancher store (networks only when named)
#   <store>  one store's boxes, e.g. man-001
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DELETE_TIMEOUT=300
DRY_RUN=false YES=false ROLES=() STORES=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes) YES=true ;;
    rancher | networks) ROLES+=("$arg") ;;
    store) STORES+=($(stores)) ;;
    *)
      store_field "$arg" 1 | grep -q . || { echo "Unknown option or store: $arg" >&2; exit 1; }
      STORES+=("$arg")
      ;;
  esac
done
[ ${#ROLES[@]} -gt 0 ] || [ ${#STORES[@]} -gt 0 ] || { ROLES=(rancher); STORES=($(stores)); }
has_role() { [[ " ${ROLES[*]} " == *" $1 "* ]]; }

run() { # command...
  if $DRY_RUN; then echo "    [dry-run] $*"; else "$@"; fi
}

# Stores first, then Rancher (reverse of the build order)
VMS=()
for s in "${STORES[@]}"; do VMS+=($(store_nodes "$s")); done
for role in rancher; do has_role "$role" && VMS+=($(nodes_of_role "$role")); done

echo "This permanently deletes on ${HYPERVISOR#root@}:"
printf '  %s\n' "${VMS[@]}"
has_role networks && printf '  network rtl-%s\n' $(isolated_stores)
if ! $DRY_RUN && ! $YES; then
  read -rp "Type 'delete' to continue: " answer
  [ "$answer" = delete ] || { echo "Aborted."; exit 1; }
fi

if [ ${#STORES[@]} -gt 0 ] && ! has_role rancher; then
  echo "==> Removing store clusters from Rancher"
  if ! rancher_login 2>/dev/null; then
    echo "ERROR: cannot log in to ${RANCHER_URL}; start Rancher first or include the rancher role" >&2
    exit 1
  fi
  for s in "${STORES[@]}"; do
    if api GET "/v1/provisioning.cattle.io.clusters/fleet-default/store-${s}" >/dev/null; then
      echo "    deleting cluster store-${s}"
      run api DELETE "/v1/provisioning.cattle.io.clusters/fleet-default/store-${s}" >/dev/null
    fi
  done
  if ! $DRY_RUN; then
    waited=0
    for s in "${STORES[@]}"; do
      while api GET "/v1/provisioning.cattle.io.clusters/fleet-default/store-${s}" >/dev/null; do
        if [ $waited -ge $DELETE_TIMEOUT ]; then
          echo "    WARNING: store-${s} still being removed after ${DELETE_TIMEOUT}s; Rancher will finish it" >&2
          break
        fi
        sleep 5
        waited=$((waited + 5))
      done
    done
  fi
fi

echo "==> Deleting VMs"
for vm in "${VMS[@]}"; do
  if ! $SSH "$HYPERVISOR" "virsh dominfo ${vm}" &>/dev/null; then
    echo "    ${vm}: not defined, skipping"
    continue
  fi
  echo "    ${vm}"
  # Only the VM's own disk is removed, never an installer ISO that may still be attached
  run $SSH "$HYPERVISOR" \
    "virsh domstate ${vm} | grep -qx 'shut off' || virsh destroy ${vm} >/dev/null
     virsh undefine ${vm} --nvram --tpm --storage ${HV_DISKS}/${vm}.qcow2 >/dev/null"
  ip=$(ip_of "$vm")
  [ -n "$ip" ] && { run ssh-keygen -R "$ip" &>/dev/null || true; }
done

if has_role networks; then
  echo "==> Deleting store networks"
  for s in $(isolated_stores); do
    $SSH "$HYPERVISOR" "virsh net-info rtl-${s}" &>/dev/null || continue
    echo "    rtl-${s}"
    run $SSH "$HYPERVISOR" "virsh net-destroy rtl-${s} >/dev/null; virsh net-undefine rtl-${s} >/dev/null"
  done
fi

echo "==> Done. Rebuild with ./create-vms.sh (see README.md, Build order)."
