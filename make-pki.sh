#!/bin/bash
# Create the retail-shed CA and Rancher's server certificate in pki/ (once).
# Store images trust the CA, so boxes register with Rancher's verified command
# instead of demo-shed's insecure one. The keys are gitignored.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${DIR}/pki"
if [ -f ca.pem ]; then
  echo "pki/ca.pem exists; delete pki/* to start again (store images must then be rebuilt)"
  exit 0
fi
umask 077
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout ca.key -out ca.pem -subj "/O=retail-shed/CN=retail-shed HQ CA" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
openssl req -newkey rsa:2048 -nodes -keyout rancher.key -out rancher.csr \
  -subj "/O=retail-shed/CN=${RANCHER_FQDN}"
openssl x509 -req -in rancher.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out rancher.pem -days 825 -sha256 -extfile <(printf '%s\n' \
    "subjectAltName=DNS:${RANCHER_FQDN},IP:${VIP}" \
    "extendedKeyUsage=serverAuth" "keyUsage=critical,digitalSignature,keyEncipherment")
rm -f rancher.csr ca.srl
chmod 644 ca.pem rancher.pem
echo "==> pki/ca.pem, pki/rancher.pem"
