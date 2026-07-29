#!/usr/bin/env bash
set -Eeuo pipefail

# Analyse OPNsense NetFlow (Insight) data for CROSS-ZONE flows.
#
# Part of the segmentation-hardening project (Phase 0/1): shows which zone talks
# to which internal destination on which port, so the access matrix can be
# redesigned from real traffic instead of guesses. Read-only.
#
# Source: /var/netflow/src_addr_details_086400.sqlite on glados (OPNsense), table
# `timeserie` (src_addr, dst_addr, service_port, protocol, octets, packets).
#
# Usage: ./netflow-crosszone.sh            # cross-zone internal flows only
#        ./netflow-crosszone.sh --all      # also include internet-bound flows
#
# Requires: ssh access to root@glados.lan.

GLADOS="${GLADOS_HOST:-glados.lan}"
DB="/var/netflow/src_addr_details_086400.sqlite"
INCLUDE_INTERNET="${1:-}"

# Map 10.1.<octet3>.x -> zone (from infra/data/networks.yaml).
zone_of() {
  case "$1" in
    10.1.1.*)   echo untrusted ;;
    10.1.10.*)  echo servers ;;
    10.1.11.*)  echo k8s-lb ;;
    10.1.20.*)  echo clients ;;
    10.1.30.*)  echo iot ;;
    10.1.40.*)  echo iot_local ;;
    10.1.50.*)  echo guest ;;
    10.1.100.*) echo vpn ;;
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) echo internal-other ;;
    *) echo internet ;;
  esac
}

echo "Pulling flow tuples from ${GLADOS}:${DB} ..."
rows="$(ssh -o ConnectTimeout=8 "root@${GLADOS}" "sh -c 'sqlite3 -separator \"|\" ${DB} \"SELECT src_addr,dst_addr,service_port,protocol,SUM(octets),SUM(packets) FROM timeserie GROUP BY src_addr,dst_addr,service_port,protocol ORDER BY SUM(octets) DESC\"'")"

if [ -z "${rows}" ]; then
  echo "No flow data yet (NetFlow needs time to accumulate). Try again later."
  exit 0
fi

printf '%-11s %-15s -> %-14s %-15s %5s/%-4s %12s %10s\n' \
  SRC-ZONE SRC DST-ZONE DST PORT PROT OCTETS PACKETS
echo "--------------------------------------------------------------------------------------------"

echo "${rows}" | while IFS='|' read -r src dst port proto octets packets; do
  [ -z "${src}" ] && continue
  sz="$(zone_of "${src}")"; dz="$(zone_of "${dst}")"
  # cross-zone only (different zone); skip same-zone
  [ "${sz}" = "${dz}" ] && continue
  # by default skip internet destinations (we care about internal segmentation)
  if [ "${INCLUDE_INTERNET}" != "--all" ] && [ "${dz}" = "internet" ]; then
    continue
  fi
  printf '%-11s %-15s -> %-14s %-15s %5s/%-4s %12s %10s\n' \
    "${sz}" "${src}" "${dz}" "${dst}" "${port}" "${proto}" "${octets}" "${packets}"
done
