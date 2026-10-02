#!/bin/bash
# Simulate a store's WAN link on vrack0 with tc on the store's bridge (rtl-<store>).
#
# Usage: ./wan.sh status
#        ./wan.sh degrade <store|all> <delay-ms> [loss-%] [rate, e.g. 20mbit]
#        ./wan.sh outage  <store|all>
#        ./wan.sh restore <store|all>
#
# The shaping applies to everything routed into the store (HQ -> store, which
# includes every reply the store gets from HQ), so delay adds once per round
# trip. Traffic between nodes inside the store LAN, and ARP/DHCP/DNS from the
# store router (.1), is never touched: a WAN outage leaves the store LAN working.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HSSH="ssh -o BatchMode=yes ${HYPERVISOR}"

targets() {
  if [ "$1" = all ]; then isolated_stores; return; fi
  store_field "$1" 1 | grep -q . || { echo "unknown store $1" >&2; exit 1; }
  [ "$(store_field "$1" 4)" != lan ] || { echo "$1 is on the HQ LAN: there is no store link to shape" >&2; exit 1; }
  echo "$1"
}

shape() { # store netem-args [rate]
  local br="rtl-$1" gw="${STORE_NET_PREFIX}.$(store_field "$1" 4).1" netem=$2 rate=${3:-10gbit}
  $HSSH "set -e
    tc qdisc del dev ${br} root 2>/dev/null || true
    tc qdisc add dev ${br} root handle 1: htb default 20
    tc class add dev ${br} parent 1: classid 1:10 htb rate 10gbit quantum 60000
    tc class add dev ${br} parent 1: classid 1:20 htb rate ${rate} ceil ${rate} quantum 60000
    tc qdisc add dev ${br} parent 1:20 handle 20: netem ${netem}
    tc filter add dev ${br} parent 1: prio 1 protocol arp matchall flowid 1:10
    tc filter add dev ${br} parent 1: prio 2 protocol ip u32 match ip src ${gw}/32 flowid 1:10"
}

case "${1:-status}" in
  status)
    for s in $(isolated_stores); do
      q=$($HSSH "tc qdisc show dev rtl-${s} 2>/dev/null" | awk '$2 == "netem" { sub(/.*limit [0-9]+ /, ""); sub(/ seed [0-9]+/, ""); print; exit }')
      r=$($HSSH "tc class show dev rtl-${s} 2>/dev/null | awk '/1:20/ { for (i=1;i<=NF;i++) if (\$i==\"rate\") print \$(i+1) }' || true")
      [ "$r" = 10Gbit ] && r=""
      printf '%-8s %s\n' "$s" "${q:-normal}${q:+${r:+ rate ${r}}}"
    done
    ;;
  degrade)
    [ $# -ge 3 ] || { sed -n '4,8p' "$0"; exit 1; }
    for s in $(targets "$2"); do
      shape "$s" "delay ${3}ms $(( $3 / 10 ))ms loss ${4:-0}%" "${5:-}"
      echo "${s}: ${3}ms delay, ${4:-0}% loss${5:+, ${5}}"
    done
    ;;
  outage)
    for s in $(targets "${2:?store|all}"); do
      shape "$s" "loss 100%"
      echo "${s}: WAN down"
    done
    ;;
  restore)
    for s in $(targets "${2:?store|all}"); do
      $HSSH "tc qdisc del dev rtl-${s} root 2>/dev/null || true"
      echo "${s}: WAN normal"
    done
    ;;
  *) sed -n '4,8p' "$0"; exit 1 ;;
esac
