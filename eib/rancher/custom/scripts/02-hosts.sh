#!/bin/bash
# No DNS zone for retail-shed.local on the HQ LAN: pin the Rancher name to the keepalived VIP
echo "172.16.0.251 rancher.retail-shed.local rancher" >> /etc/hosts
