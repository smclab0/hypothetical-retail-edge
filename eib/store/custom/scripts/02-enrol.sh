#!/bin/bash
# Install the HQ CA and the first-boot enrolment service (files come from custom/files).
# The CA bundle is generated under /var, a separate subvolume from the
# transactional snapshot combustion writes, so retail-enrol runs
# update-ca-certificates at boot instead of here.
set -euo pipefail
install -D -m 0644 retail-shed-ca.pem /etc/pki/trust/anchors/retail-shed-ca.pem
install -d -m 0700 /etc/retail-enrol
install -m 0600 enrol.env /etc/retail-enrol/enrol.env
# /usr/libexec, not /usr/local: on SL Micro /usr/local (like /opt and /var) is a
# separate subvolume mounted over the snapshot, which hides anything written there
install -D -m 0755 retail-enrol.sh /usr/libexec/retail-enrol
install -D -m 0644 retail-enrol.service /etc/systemd/system/retail-enrol.service
systemctl enable retail-enrol.service
