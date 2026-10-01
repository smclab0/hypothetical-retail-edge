#!/bin/bash
# Install the HQ CA and the first-boot enrolment service (files come from custom/files).
# No update-ca-certificates here: it writes the bundle under /var, which is not
# writable in combustion's transactional chroot. retail-enrol runs it at boot.
set -euo pipefail
install -m 0644 retail-shed-ca.pem /etc/pki/trust/anchors/retail-shed-ca.pem
install -d -m 0700 /etc/retail-enrol
install -m 0600 enrol.env /etc/retail-enrol/enrol.env
install -m 0755 retail-enrol.sh /usr/local/bin/retail-enrol
install -m 0644 retail-enrol.service /etc/systemd/system/retail-enrol.service
systemctl enable retail-enrol.service
