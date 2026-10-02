#!/bin/bash
# Define one isolated libvirt NAT network per store on vrack0 (from stores.txt).
# Each store LAN is 10.120.<net>.0/24 on bridge rtl-<store>. The "store router"
# (libvirt's dnsmasq at .1) hands out fixed addresses .11, .12, ... by MAC and
# answers rancher.retail-shed.local with the HQ VIP, so boxes need no /etc/hosts
# entries. Traffic to HQ is NATed out through vrack0; libvirt blocks forwarding
# between store networks, so stores can't reach each other.
# Usage: ./create-networks.sh [--dry-run]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DRY_RUN=false
[ "${1:-}" = --dry-run ] && DRY_RUN=true

for s in $(isolated_stores); do
  net=$(store_field "$s" 4)
  name="rtl-${s}"
  hosts=""
  for n in $(store_nodes "$s"); do
    hosts+="      <host mac='$(mac_of "$n")' name='${n}' ip='$(ip_of "$n")'/>"$'\n'
  done
  xml="<network>
  <name>${name}</name>
  <forward mode='nat'/>
  <bridge name='${name}' stp='on' delay='0'/>
  <domain name='${s}.store.retail-shed.local' localOnly='yes'/>
  <dns>
    <host ip='${VIP}'><hostname>${RANCHER_FQDN}</hostname></host>
  </dns>
  <ip address='${STORE_NET_PREFIX}.${net}.1' prefix='24'>
    <dhcp>
      <range start='${STORE_NET_PREFIX}.${net}.100' end='${STORE_NET_PREFIX}.${net}.199'/>
${hosts}    </dhcp>
  </ip>
</network>"
  if $DRY_RUN; then
    echo "$xml"
    continue
  fi
  if $SSH "$HYPERVISOR" "virsh net-info ${name}" &>/dev/null; then
    echo "==> ${name}: already defined"
    continue
  fi
  echo "==> ${name} (${STORE_NET_PREFIX}.${net}.0/24)"
  ssh -o BatchMode=yes "$HYPERVISOR" "cat > /tmp/${name}.xml && virsh net-define /tmp/${name}.xml >/dev/null &&
    virsh net-autostart ${name} >/dev/null && virsh net-start ${name} >/dev/null && rm /tmp/${name}.xml" <<<"$xml"
done
