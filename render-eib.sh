#!/bin/bash
# Render the EIB definitions from eib/*/templates using eib/secrets.env.
# Usage: ./render-eib.sh rancher|store
#   Each name is a directory under eib/ with its own EIB build context.
#   store  retail-store.yaml plus the box's enrolment files. Needs Rancher up and
#          ENROL_TOKEN in credentials.env (setup-stores.sh --enrol-only creates it).
# The rendered files hold secrets and are gitignored.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -gt 0 ] || { echo "usage: $0 rancher|store" >&2; exit 1; }
SETS=("$@")

if [ ! -f "${DIR}/eib/secrets.env" ]; then
  echo "ERROR: eib/secrets.env missing - copy secrets.env.example and fill it in" >&2
  exit 1
fi
set -a
source "${DIR}/eib/secrets.env"
set +a

for which in "${SETS[@]}"; do
[ -d "${DIR}/eib/${which}/templates" ] || { echo "ERROR: no eib/${which}" >&2; exit 1; }
if [ "$which" = store ]; then
  source "${DIR}/credentials.env"
  if [ -z "${ENROL_TOKEN:-}" ]; then
    echo "ERROR: no ENROL_TOKEN in credentials.env - run ./setup-stores.sh --enrol-only first" >&2
    exit 1
  fi
  files="${DIR}/eib/store/custom/files"
  cp "${DIR}/pki/ca.pem" "${files}/retail-shed-ca.pem"
  (umask 077; printf 'RANCHER_URL=%s\nENROL_TOKEN=%s\n' "$RANCHER_URL" "$ENROL_TOKEN" >"${files}/enrol.env")
  echo "==> ${files}/enrol.env, retail-shed-ca.pem"
fi

for tmpl in "${DIR}/eib/${which}"/templates/*.yaml.tmpl; do
  out="${DIR}/eib/${which}/$(basename "${tmpl%.tmpl}")"
  envsubst '${SCC_REG_CODE} ${ROOT_PASSWORD_HASH}' <"$tmpl" >"$out"
  echo "==> ${out}"
done
done
