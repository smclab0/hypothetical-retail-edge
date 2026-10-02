#!/bin/bash
# Find the DHCP addresses of every VM on br0 (Rancher nodes and HQ-LAN stores)
# by MAC and write hosts.txt.
# Sweeps 172.16.0.0/24 from vrack0 to fill its neighbour table, then matches MACs.
# Stores on their own networks have fixed addresses (see ip_of in lib.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

neigh=$($SSH "$HYPERVISOR" '
  for i in $(seq 1 254); do ping -c1 -W1 172.16.0.$i >/dev/null 2>&1 & done; wait
  ip -4 neigh show dev br0')

tmp=$(mktemp)
echo "# Written by discover-ips.sh $(date -Iseconds)" >"$tmp"
missing=0
for name in $(awk '!/^#/ && $4 == "br0" { print $1 }' "${DIR}/nodes.txt"); do
  # MetalLB answers ARP for the VIP with the announcing node's MAC: skip it
  ip=$(awk -v m="$(mac_of "$name")" -v vip="$VIP" 'tolower($3) == m && $1 != vip { print $1; exit }' <<<"$neigh")
  if [ -z "$ip" ]; then
    echo "WARNING: no address found for ${name}" >&2
    missing=1
    continue
  fi
  printf '%-18s %s\n' "$name" "$ip" | tee -a "$tmp"
done
mv "$tmp" "${DIR}/hosts.txt"
[ $missing -eq 0 ] || exit 1
