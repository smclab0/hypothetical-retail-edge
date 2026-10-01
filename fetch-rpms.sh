#!/bin/bash
# Download the side-loaded RPMs into eib/<set>/rpms and verify each against the
# Rancher key in rpms/gpg-keys. Side-loading avoids two rpm.rancher.io problems:
# the k3s SL Micro repo has unsigned metadata, and a CDN-cached repomd.xml can
# go stale against a fresh signature after a release. It also pins versions.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RKE2_VERSION=1.35.8~rke2r1
RPM=https://rpm.rancher.io

fetch() { # set url
  local dest="${DIR}/eib/$1/rpms" f
  f=$(basename "$2")
  [ -f "${dest}/${f}" ] || { echo "==> $1: ${f}"; curl -sfL -o "${dest}/${f}" "$2"; }
}
fetch rancher "${RPM}/rke2/stable/1.35/slemicro/x86_64/rke2-server-${RKE2_VERSION}-0.slemicro.x86_64.rpm"
fetch rancher "${RPM}/rke2/stable/1.35/slemicro/x86_64/rke2-common-${RKE2_VERSION}-0.slemicro.x86_64.rpm"
fetch rancher "${RPM}/rke2/stable/common/slemicro/noarch/rke2-selinux-0.23-1.slemicro.noarch.rpm"
fetch store "${RPM}/k3s/stable/common/slemicro/noarch/k3s-selinux-1.6-1.slemicro.noarch.rpm"

db=$(mktemp -d)
trap 'rm -rf "$db"' EXIT
rpm --dbpath "$db" --import "${DIR}/eib/rancher/rpms/gpg-keys/rancher-public.key"
rpm --dbpath "$db" -K "${DIR}"/eib/*/rpms/*.rpm
