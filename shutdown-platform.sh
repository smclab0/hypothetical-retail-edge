#!/bin/bash
# Power down retail-shed in dependency order:
#   1. stores (in parallel; within a store the highest node first, n1 last)
#   2. Rancher cluster (retail-rancher03 -> 02 -> 01)
# Each cluster gets an etcd snapshot first. Node n1 / 01 goes down last, so
# start it first when powering back on (startup-platform.sh does).
#
# Usage: ./shutdown-platform.sh [--dry-run] [--no-snapshot] [--force]
#   --dry-run      print the steps without doing anything
#   --no-snapshot  skip the etcd snapshots
#   --force        hard power-off (virsh destroy) a VM that ignores shutdown
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SHUTDOWN_TIMEOUT=300
DRY_RUN=false SNAPSHOT=true FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --no-snapshot) SNAPSHOT=false ;;
    --force) FORCE=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

run() { # prefix command...
  local prefix=$1; shift
  if $DRY_RUN; then echo "${prefix} [dry-run] $*"; else "$@"; fi
}

# RKE2 on the Rancher nodes, K3s (installed by Rancher's system agent) in the stores
k8s_cmd() { if [[ "$1" == store-* ]]; then echo k3s; else echo rke2; fi; }

snapshot() { # prefix vm
  local k8s
  k8s=$(k8s_cmd "$2")
  echo "$1 etcd snapshot on $2"
  run "$1" ssh_node "$2" "PATH=\$PATH:/usr/local/bin:/opt/bin:/opt/rke2/bin
    ${k8s} etcd-snapshot save --name pre-shutdown-\$(date +%Y%m%d-%H%M) >/dev/null 2>&1" ||
    echo "$1 WARNING: snapshot on $2 failed, continuing" >&2
}

power_off() { # prefix vm
  local prefix=$1 vm=$2 waited=0 k8s
  k8s=$(k8s_cmd "$vm")
  echo "${prefix} stopping ${vm}"
  # Stop Kubernetes first so etcd shuts down cleanly
  run "$prefix" ssh_node "$vm" \
    "for u in ${k8s}-server ${k8s}-agent ${k8s}; do systemctl is-active -q \$u && systemctl stop \$u; done; true" || true
  run "$prefix" $SSH "$HYPERVISOR" "virsh shutdown ${vm} >/dev/null"
  $DRY_RUN && return
  until [ "$($SSH "$HYPERVISOR" "virsh domstate ${vm}")" = "shut off" ]; do
    if [ $waited -ge $SHUTDOWN_TIMEOUT ]; then
      if $FORCE; then
        echo "${prefix} ${vm} ignored shutdown for ${SHUTDOWN_TIMEOUT}s, forcing power-off"
        $SSH "$HYPERVISOR" "virsh destroy ${vm} >/dev/null"
        break
      fi
      echo "${prefix} ERROR: ${vm} still running after ${SHUTDOWN_TIMEOUT}s (rerun with --force)" >&2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "${prefix} ${vm} is off"
}

running() { [ "$($SSH "$HYPERVISOR" "virsh domstate $1 2>/dev/null")" = running ]; }

shutdown_group() { # label vm... (first vm is node 1; it goes down last)
  local label=$1 vms
  shift
  running "$1" && $SNAPSHOT && snapshot "[${label}]" "$1"
  vms=("$@")
  for ((i = ${#vms[@]} - 1; i >= 0; i--)); do
    running "${vms[$i]}" || { echo "[${label}] ${vms[$i]} already off"; continue; }
    power_off "[${label}]" "${vms[$i]}"
  done
}

echo "==> Stores"
pids=()
for s in $(stores); do
  shutdown_group "$s" $(store_nodes "$s") &
  pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
if [ $failed -ne 0 ]; then
  echo "ERROR: a store did not shut down; leaving Rancher running" >&2
  exit 1
fi

echo "==> Rancher cluster"
shutdown_group rancher $(nodes_of_role rancher)

echo "==> All retail-shed VMs are off. Start with ./startup-platform.sh"
