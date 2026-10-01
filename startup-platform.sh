#!/bin/bash
# Power up retail-shed in dependency order (reverse of shutdown-platform.sh):
#   1. Rancher cluster (01 -> 03), wait for 3 nodes Ready, the MetalLB VIP and
#      Rancher answering on it
#   2. stores (in parallel, n1 first), wait for Rancher to report each store ready
# The next node starts as soon as the previous one answers SSH: etcd needs a
# quorum before anything reports Ready.
#
# Usage: ./startup-platform.sh [--dry-run]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BOOT_TIMEOUT=300
READY_TIMEOUT=900
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"

step_wait() { # prefix description timeout command...
  local prefix=$1; shift
  if $DRY_RUN; then echo "${prefix} [dry-run] wait for $1"; return; fi
  wait_for "$@" | sed "s/^ */${prefix} /"
  return "${PIPESTATUS[0]}"
}

power_on() { # prefix vm
  local prefix=$1 vm=$2
  if $DRY_RUN; then
    echo "${prefix} [dry-run] virsh start ${vm}, wait for SSH on $(ip_of "$vm")"
    return
  fi
  if [ "$($SSH "$HYPERVISOR" "virsh domstate ${vm}")" = running ]; then
    echo "${prefix} ${vm} already running"
  else
    echo "${prefix} starting ${vm}"
    $SSH "$HYPERVISOR" "virsh start ${vm} >/dev/null"
  fi
  if ! step_wait "$prefix" "${vm} SSH" "$BOOT_TIMEOUT" ssh_node "$vm" true; then
    # HQ addresses come from DHCP; say so if the lease moved
    [[ "$vm" == store-* ]] && return 1
    local seen
    seen=$($SSH "$HYPERVISOR" "ip neigh | awk -v m=$(mac_of "$vm") 'tolower(\$5) == m { print \$1 }'" || true)
    [ -n "$seen" ] && [ "$seen" != "$(ip_of "$vm")" ] &&
      echo "${prefix} ${vm} is now at ${seen} (DHCP lease changed): run ./discover-ips.sh" >&2
    return 1
  fi
}

rancher_nodes_ready() {
  [ "$($SSH root@"$(ip_of retail-rancher01)" "$KUBECTL get nodes --no-headers" | awk '$2 == "Ready"' | wc -l)" -eq 3 ]
}
store_ready() { # store
  [ "$($SSH root@"$(ip_of retail-rancher01)" \
    "$KUBECTL -n fleet-default get clusters.provisioning.cattle.io store-$1 -o jsonpath='{.status.ready}'")" = true ]
}

echo "==> Rancher cluster"
for vm in $(nodes_of_role rancher); do power_on "[rancher]" "$vm"; done
step_wait "[rancher]" "3/3 nodes Ready" "$READY_TIMEOUT" rancher_nodes_ready
# kube-proxy doesn't answer ping on a LoadBalancer IP, so test the API port
step_wait "[rancher]" "MetalLB VIP ${VIP}:6443" "$READY_TIMEOUT" curl -sk --max-time 3 -o /dev/null "https://${VIP}:6443/"
step_wait "[rancher]" "Rancher /ping through the VIP" "$READY_TIMEOUT" \
  sh -c "curl -sf --cacert '${DIR}/pki/ca.pem' --max-time 5 --resolve ${RANCHER_FQDN}:443:${VIP} ${RANCHER_URL}/ping | grep -qx pong"

echo "==> Stores"
start_store() { # store
  for vm in $(store_nodes "$1"); do power_on "[$1]" "$vm" || return 1; done
  step_wait "[$1]" "Rancher reports store-$1 ready" "$READY_TIMEOUT" store_ready "$1"
}
pids=()
for s in $(stores); do
  start_store "$s" &
  pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
[ $failed -eq 0 ] || { echo "ERROR: a store did not come up" >&2; exit 1; }

echo "==> retail-shed is up: ${RANCHER_URL}"
