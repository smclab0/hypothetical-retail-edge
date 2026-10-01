#!/bin/bash
# Copy eib/<set> to vrack0 and build its ISOs with Edge Image Builder there.
# Usage: ./build-images.sh rancher|store
# Run fetch-rpms.sh and render-eib.sh for the same sets first.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -gt 0 ] || { echo "usage: $0 rancher|store" >&2; exit 1; }
SETS=("$@")
EIB_IMAGE=registry.suse.com/edge/3.4/edge-image-builder:1.3.1
BASE_ISO=SL-Micro.x86_64-6.2-Default-SelfInstall-GM.install.iso
HSSH="ssh -o BatchMode=yes ${HYPERVISOR}"

for which in "${SETS[@]}"; do
echo "==> Copying eib/${which} to ${HYPERVISOR#root@}:${HV_BASE}/eib/${which}"
$HSSH "mkdir -p ${HV_BASE}/eib/${which}/base-images"
rsync -a --delete --exclude base-images/ --exclude _build/ --exclude '*.iso' \
  "${DIR}/eib/${which}/" "${HYPERVISOR}:${HV_BASE}/eib/${which}/"
# Reuse the base ISO already on vrack0 (hard link, same filesystem)
$HSSH "cd ${HV_BASE}/eib/${which}/base-images && [ -f ${BASE_ISO} ] ||
  ln /mnt/datastore/vmdata/demo-shed/eib/base-images/${BASE_ISO} ${BASE_ISO}"

for def in "${DIR}/eib/${which}"/retail-*.yaml; do
  def=$(basename "$def")
  echo "==> Building ${def%.yaml}.iso"
  # EIB's own output is long; keep the tail, but fail on a failed build
  if ! $HSSH "cd ${HV_BASE}/eib/${which} && podman run --rm --privileged -v \$PWD:/eib ${EIB_IMAGE} \
    build --definition-file ${def}" >"${DIR}/eib/${which}/build.log" 2>&1; then
    tail -5 "${DIR}/eib/${which}/build.log"
    echo "ERROR: ${def} failed; see eib-build.log in ${HV_BASE}/eib/${which}/_build/<latest>" >&2
    exit 1
  fi
  tail -1 "${DIR}/eib/${which}/build.log"
done
$HSSH "ls -lh ${HV_BASE}/eib/${which}/*.iso"
done
