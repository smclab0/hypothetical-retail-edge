#!/bin/bash
# HQ side of store onboarding.
#   1. Enrolment identity: a Rancher user "store-enrol" whose global role can only
#      read provisioning clusters and cluster registration tokens, plus an API
#      token for it saved as ENROL_TOKEN in credentials.env. render-eib.sh bakes
#      that token into the generic store image.
#   2. Store records: one K3s custom cluster store-<store> per line of stores.txt,
#      labelled retail.lab/{store,region,tier} for Fleet targeting. A box that
#      boots before its record exists keeps waiting for it.
#
# Usage: ./setup-stores.sh [--enrol-only] [store...]   (default: every store)
#   K3S_VERSION=v1.35.x+k3s1 overrides the newest 1.35 K3s Rancher offers.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ENROL_ONLY=false SEL=()
for arg in "$@"; do
  case "$arg" in
    --enrol-only) ENROL_ONLY=true ;;
    *) SEL+=("$arg") ;;
  esac
done
[ ${#SEL[@]} -gt 0 ] || SEL=($(stores))

echo "==> Logging in to ${RANCHER_URL}"
rancher_login

# --- 1. Enrolment identity ---------------------------------------------------
enrol_api() { # path
  curl -sf --cacert "${DIR}/pki/ca.pem" --resolve "${RANCHER_FQDN}:443:${VIP}" \
    -H "Authorization: Bearer ${ENROL_TOKEN}" "${RANCHER_URL}$1"
}

if [ -n "${ENROL_TOKEN:-}" ] && enrol_api /v1/provisioning.cattle.io.clusters/fleet-default >/dev/null; then
  echo "==> Enrolment token in credentials.env still works"
else
  echo "==> Creating the store-enrol role, user and token"
  if ! api GET /v1/management.cattle.io.globalroles/store-enrol >/dev/null; then
    api POST /v1/management.cattle.io.globalroles '{
      "metadata": {"name": "store-enrol"},
      "displayName": "Store enrolment (read-only)",
      "description": "Used by store boxes at first boot to find their cluster registration command",
      "rules": [
        {"apiGroups": ["provisioning.cattle.io"], "resources": ["clusters"], "verbs": ["get", "list"]},
        {"apiGroups": ["management.cattle.io"], "resources": ["clusterregistrationtokens"], "verbs": ["get", "list"]}
      ]}' >/dev/null
  fi

  ENROL_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
  user_id=$(api GET '/v3/users?username=store-enrol' | jq -r '.data[0].id // empty')
  if [ -z "$user_id" ]; then
    user_id=$(api POST /v3/users "$(jq -n --arg p "$ENROL_PASSWORD" '{
      username: "store-enrol", name: "Store enrolment", password: $p,
      mustChangePassword: false, enabled: true}')" | jq -er .id)
    api POST /v3/globalrolebindings "{\"globalRoleId\":\"store-enrol\",\"userId\":\"${user_id}\"}" >/dev/null
  else
    api POST "/v3/users/${user_id}?action=setpassword" "{\"newPassword\":\"${ENROL_PASSWORD}\"}" >/dev/null
  fi

  session=$(curl -sf --cacert "${DIR}/pki/ca.pem" --resolve "${RANCHER_FQDN}:443:${VIP}" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"store-enrol\",\"password\":\"${ENROL_PASSWORD}\",\"responseType\":\"token\"}" \
    "${RANCHER_URL}/v3-public/localProviders/local?action=login" | jq -er .token)
  token_json=$(curl -sf --cacert "${DIR}/pki/ca.pem" --resolve "${RANCHER_FQDN}:443:${VIP}" \
    -H "Authorization: Bearer ${session}" -H 'Content-Type: application/json' \
    -d '{"type":"token","description":"store box enrolment","ttl":0}' "${RANCHER_URL}/v3/tokens")
  ENROL_TOKEN=$(jq -er .token <<<"$token_json")
  echo "    token expires: $(jq -r '.expiresAt // "never"' <<<"$token_json" | sed 's/^$/never/')"
  sed -i '/^ENROL_TOKEN=/d' "${DIR}/credentials.env"
  echo "ENROL_TOKEN=${ENROL_TOKEN}" >>"${DIR}/credentials.env"

  wait_for "store-enrol can list clusters" 60 enrol_api /v1/provisioning.cattle.io.clusters/fleet-default
  echo "    NOTE: the store image must be re-rendered and rebuilt to carry this token"
fi
$ENROL_ONLY && exit 0

# --- 2. Store records --------------------------------------------------------
if [ -z "${K3S_VERSION:-}" ]; then
  K3S_VERSION=$(api GET /v1-k3s-release/releases | jq -r '.data[].version' |
    grep '^v1\.35\.' | sort -V | tail -1)
fi
[ -n "$K3S_VERSION" ] || { echo "ERROR: Rancher offers no v1.35 K3s; set K3S_VERSION" >&2; exit 1; }
echo "==> Store clusters run K3s ${K3S_VERSION}"

for s in "${SEL[@]}"; do
  region=$(store_field "$s" 2)
  tier=$(store_field "$s" 3)
  [ -n "$region" ] || { echo "ERROR: ${s} is not in stores.txt" >&2; exit 1; }
  c="store-${s}"
  if api GET "/v1/provisioning.cattle.io.clusters/fleet-default/${c}" >/dev/null; then
    echo "    ${c}: exists"
    continue
  fi
  echo "    ${c}: creating (${region}, ${tier}, $(store_nodes "$s" | wc -l) node(s))"
  api POST /v1/provisioning.cattle.io.clusters "$(jq -n --arg name "$c" --arg ver "$K3S_VERSION" \
    --arg store "$s" --arg region "$region" --arg tier "$tier" '{
      type: "provisioning.cattle.io.cluster",
      metadata: {name: $name, namespace: "fleet-default",
        labels: {"retail.lab/store": $store, "retail.lab/region": $region, "retail.lab/tier": $tier}},
      spec: {kubernetesVersion: $ver, rkeConfig: {}}
    }')" >/dev/null
done
echo "==> Store records ready; boxes enrol themselves when they boot."
