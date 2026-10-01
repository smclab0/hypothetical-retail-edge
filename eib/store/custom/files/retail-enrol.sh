#!/bin/bash
# First-boot enrolment of a store box. The box identifies itself from its
# SMBIOS serial (store-<store>-n<N>), names itself after it, waits until HQ has
# created the cluster store-<store> in Rancher, then runs that cluster's
# registration command. Every store node gets etcd + control plane + worker.
#
# /etc/retail-enrol/enrol.env holds RANCHER_URL and ENROL_TOKEN, a read-only
# Rancher token that can only list clusters and their registration tokens.
set -euo pipefail

source /etc/retail-enrol/enrol.env
STATE=/var/lib/retail-enrol

# Trust the HQ CA (installed as an anchor by the image; the bundle lives in /var)
update-ca-certificates

serial=$(tr -d '[:space:]' </sys/class/dmi/id/product_serial)
if [[ ! "$serial" =~ ^store-([a-z]+-[0-9]+)-n[0-9]+$ ]]; then
  echo "serial '${serial}' is not a store box (want store-<store>-n<N>)" >&2
  exit 1
fi
store=${BASH_REMATCH[1]}
cluster="store-${store}"
hostnamectl set-hostname "$serial"
echo "box ${serial}: enrolling into ${cluster}"

api() { curl -sf --max-time 20 -H "Authorization: Bearer ${ENROL_TOKEN}" "${RANCHER_URL}$1"; }

# HQ may not have created the store record yet, or the WAN may be down: keep trying
until mgmt=$(api "/v1/provisioning.cattle.io.clusters/fleet-default/${cluster}" |
  jq -er '.status.clusterName | select(. != null and . != "")'); do
  echo "waiting for ${cluster} at ${RANCHER_URL}"
  sleep 30
done
until cmd=$(api "/v1/management.cattle.io.clusterregistrationtokens/${mgmt}" |
  jq -er '[.data[].status.nodeCommand | select(. != null and . != "")][0]'); do
  echo "waiting for the ${cluster} registration token"
  sleep 15
done

# The HQ CA is in the system trust store, so this is the verified (non-insecure) command
bash -c "${cmd} --etcd --controlplane --worker --label retail.lab/store=${store}"

# The installer only logs a failed systemctl call (seen once on a first boot
# when the system bus was not up yet), so make sure the agent really runs
systemctl enable --now rancher-system-agent.service
systemctl is-active --quiet rancher-system-agent.service

install -d -m 0700 "$STATE"
date -Iseconds >"${STATE}/done"
echo "box ${serial}: registered with ${cluster}"
