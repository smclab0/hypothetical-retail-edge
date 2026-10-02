#!/bin/bash
# Render the Agama profile for kiosk store boxes (SLES 16 + GNOME + K3s).
# Output: agama/kiosk/retail-kiosk.json (holds secrets; gitignored).
#
# The box payload - the same enrolment service and token as the SL Micro store
# image, the HQ CA, k3s-selinux and the kiosk session files - travels as a
# tarball inside the post-install script, so the install needs nothing but
# the SLES 16 Full ISO and this profile.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
K="${DIR}/agama/kiosk"
STORE="${DIR}/eib/store"

set -a
source "${DIR}/eib/secrets.env"
source "${DIR}/credentials.env"
set +a
[ -n "${ENROL_TOKEN:-}" ] || { echo "ERROR: no ENROL_TOKEN - run ./setup-stores.sh --enrol-only" >&2; exit 1; }
RPM=$(ls "${STORE}"/rpms/k3s-selinux-*.rpm 2>/dev/null | head -1)
[ -n "$RPM" ] || { echo "ERROR: no k3s-selinux RPM - run ./fetch-rpms.sh" >&2; exit 1; }
SSH_KEY=$(grep -m1 -oE 'ssh-(rsa|ed25519) [^ ]+ [^ ]+' "${STORE}/templates/retail-store.yaml.tmpl")

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
S="${stage}/usr/share/retail-kiosk"
install -D -m 0644 "${DIR}/pki/ca.pem" "${stage}/etc/pki/trust/anchors/retail-shed-ca.pem"
install -d -m 0700 "${stage}/etc/retail-enrol"
printf 'RANCHER_URL=%s\nENROL_TOKEN=%s\n' "$RANCHER_URL" "$ENROL_TOKEN" >"${stage}/etc/retail-enrol/enrol.env"
chmod 0600 "${stage}/etc/retail-enrol/enrol.env"
install -D -m 0755 "${STORE}/custom/files/retail-enrol.sh" "${stage}/usr/libexec/retail-enrol"
install -D -m 0644 "${STORE}/custom/files/retail-enrol.service" "${stage}/etc/systemd/system/retail-enrol.service"
install -D -m 0755 "${K}/files/retail-kiosk-launcher.sh" "${stage}/usr/libexec/retail-kiosk-launcher"
install -d "$S"
for f in waiting.html retail-kiosk.desktop gdm-custom.conf dconf-profile-user dconf-00-kiosk \
  dconf-locks-kiosk firefox-policies.json; do
  install -m 0644 "${K}/files/${f}" "${S}/${f}"
done
install -m 0644 "${STORE}/rpms/gpg-keys/rancher-public.key" "${S}/rancher-public.key"
install -m 0644 "$RPM" "${S}/k3s-selinux.rpm"

post=$(
  echo '#!/bin/bash'
  echo '# Unpack the box payload, then configure the system'
  echo "base64 -d <<'PAYLOAD' | tar -xz -C / --no-same-owner --preserve-permissions"
  # etc and usr only: archiving "." would carry the temp dir's 0700 mode onto /
  tar -C "$stage" --owner=0 --group=0 -cz etc usr | base64 -w 76
  echo 'PAYLOAD'
  tail -n +2 "${K}/files/post-install.sh"
)

KIOSK_HASH=$(openssl passwd -6 "$(openssl rand -base64 18)")
umask 077
# software.patterns uses {add: [...]}: a plain list replaces the product's
# default patterns, which drops "selinux" and boots the box with SELinux off
jq -n --arg root "$ROOT_PASSWORD_HASH" --arg key "$SSH_KEY" --arg kiosk "$KIOSK_HASH" --arg post "$post" '{
  product: {id: "SLES"},
  localization: {language: "en_GB.UTF-8", keyboard: "gb", timezone: "Europe/London"},
  software: {
    patterns: {add: ["gnome", "selinux"]},
    packages: ["MozillaFirefox", "container-selinux", "policycoreutils", "openssh-server", "curl", "jq", "tar"]
  },
  root: {hashedPassword: true, password: $root, sshPublicKey: $key},
  user: {fullName: "Store kiosk", userName: "kiosk", hashedPassword: true, password: $kiosk},
  questions: {policy: "auto"},
  scripts: {post: [{name: "retail-kiosk", chroot: true, content: $post}]}
}' >"${K}/retail-kiosk.json"
echo "==> ${K}/retail-kiosk.json ($(du -h "${K}/retail-kiosk.json" | cut -f1))"
