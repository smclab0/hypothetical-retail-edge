# Shared settings and helpers for the retail-shed scripts (sourced, not run).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPERVISOR=root@172.16.0.69
HV_BASE=/mnt/datastore/vmdata/retail-shed
HV_DISKS=/mnt/datastore/vmdata/images
VIP=172.16.0.251
RANCHER_FQDN=rancher.retail-shed.local
RANCHER_URL="https://${RANCHER_FQDN}"
STORE_NET_PREFIX=10.120
SSH="ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
# Store LANs are only routed on vrack0, so store nodes are reached through it
SSH_STORE="${SSH} -J ${HYPERVISOR}"

# nodes.txt / stores.txt / hosts.txt lookups
nodes_of_role() { awk -v r="$1" '!/^#/ && $3 == r { print $1 }' "${DIR}/nodes.txt"; }
mac_of() { awk -v h="$1" '$1 == h { print $2 }' "${DIR}/nodes.txt"; }
net_of() { awk -v h="$1" '$1 == h { print $4 }' "${DIR}/nodes.txt"; }
stores() { awk '!/^#/ && NF { print $1 }' "${DIR}/stores.txt"; }
# Stores with net "lan" sit on the HQ LAN (br0, DHCP) instead of their own
# isolated network: no store router, no WAN simulation, address in hosts.txt
isolated_stores() { awk '!/^#/ && NF && $4 != "lan" { print $1 }' "${DIR}/stores.txt"; }
store_field() { awk -v s="$1" -v f="$2" '$1 == s { print $f }' "${DIR}/stores.txt"; } # store column
store_nodes() { awk -v p="store-$1-n" '!/^#/ && index($1, p) == 1 { print $1 }' "${DIR}/nodes.txt"; }
# Store nodes have fixed addresses: 10.120.<net>.1<N> for node nN
ip_of() {
  if [[ "$1" =~ ^store-([a-z]+-[0-9]+)-n([0-9]+)$ ]] && [ "$(store_field "${BASH_REMATCH[1]}" 4)" != lan ]; then
    echo "${STORE_NET_PREFIX}.$(store_field "${BASH_REMATCH[1]}" 4).$((10 + BASH_REMATCH[2]))"
  else
    awk -v h="$1" '$1 == h { print $2 }' "${DIR}/hosts.txt" 2>/dev/null
  fi
}
ssh_node() { # name command...
  local n=$1; shift
  if [[ "$n" == store-* ]]; then $SSH_STORE root@"$(ip_of "$n")" "$@"; else $SSH root@"$(ip_of "$n")" "$@"; fi
}

# Rancher API as admin (credentials.env from setup-rancher.sh). The HQ CA in
# pki/ signs Rancher's certificate, so curl verifies it.
rancher_login() {
  source "${DIR}/credentials.env"
  TOKEN=$(curl -sf --cacert "${DIR}/pki/ca.pem" --resolve "${RANCHER_FQDN}:443:${VIP}" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"${RANCHER_BOOTSTRAP_PASSWORD}\",\"responseType\":\"token\"}" \
    "${RANCHER_URL}/v3-public/localProviders/local?action=login" | jq -er .token)
}
api() { # method path [json]
  curl -sf --cacert "${DIR}/pki/ca.pem" --resolve "${RANCHER_FQDN}:443:${VIP}" -X "$1" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    "${RANCHER_URL}$2" ${3:+-d "$3"}
}

wait_for() { # description timeout command...
  local what=$1 timeout=$2 waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    if [ $waited -ge "$timeout" ]; then
      echo "ERROR: timed out after ${timeout}s waiting for ${what}" >&2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "    ${what}: ok"
}
