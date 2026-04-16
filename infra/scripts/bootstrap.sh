#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap Proxmox with required templates and ISOs.
#
# Two stages:
#   ./bootstrap.sh download         — Download ISO + template to local machine
#   ./bootstrap.sh upload <host>    — Upload them to Proxmox
#
# Example:
#   ./bootstrap.sh download
#   ./bootstrap.sh upload localhost:8006

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../.cache"

ALPINE_TEMPLATE="alpine-3.23-default_20260116_amd64.tar.xz"
ALPINE_URL="http://download.proxmox.com/images/system/${ALPINE_TEMPLATE}"

OPNSENSE_ISO="OPNsense-25.1-dvd-amd64.iso.bz2"
OPNSENSE_URL="https://mirror.ams1.nl.leaseweb.net/opnsense/releases/25.1/${OPNSENSE_ISO}"

download() {
  mkdir -p "$CACHE_DIR"

  echo "==> Downloading Alpine LXC template"
  if [ -f "${CACHE_DIR}/${ALPINE_TEMPLATE}" ]; then
    echo "    Already cached"
  else
    curl -L -o "${CACHE_DIR}/${ALPINE_TEMPLATE}" "$ALPINE_URL"
  fi

  echo "==> Downloading OPNsense ISO"
  if [ -f "${CACHE_DIR}/OPNsense-25.1-dvd-amd64.iso" ]; then
    echo "    Already cached"
  elif [ -f "${CACHE_DIR}/${OPNSENSE_ISO}" ]; then
    echo "    Decompressing..."
    bunzip2 -k "${CACHE_DIR}/${OPNSENSE_ISO}"
  else
    curl -L -o "${CACHE_DIR}/${OPNSENSE_ISO}" "$OPNSENSE_URL"
    echo "    Decompressing..."
    bunzip2 -k "${CACHE_DIR}/${OPNSENSE_ISO}"
  fi

  echo "==> Downloads complete:"
  ls -lh "${CACHE_DIR}/"
}

upload() {
  local PROXMOX_HOST="${1:?Usage: $0 upload <proxmox-host:port>}"
  local PROXMOX_URL="https://${PROXMOX_HOST}"

  echo "==> Authenticating to Proxmox at ${PROXMOX_URL}"
  if [ -n "${PVE_PASS:-}" ]; then
    echo "    Using PVE_PASS from environment"
  else
    read -rsp "Root password: " PVE_PASS; echo
  fi

  AUTH=$(curl -sk --max-time 30 -X POST "${PROXMOX_URL}/api2/json/access/ticket" \
    --data-urlencode "username=root@pam" \
    --data-urlencode "password=${PVE_PASS}")
  TICKET=$(echo "$AUTH" | jq -r '.data.ticket')
  CSRF=$(echo "$AUTH" | jq -r '.data.CSRFPreventionToken')

  if [ "$TICKET" = "null" ] || [ -z "$TICKET" ]; then
    echo "ERROR: Authentication failed"
    exit 1
  fi

  echo "==> Uploading Alpine template"
  curl -sk --max-time 600 -X POST \
    -b "PVEAuthCookie=${TICKET}" \
    -H "CSRFPreventionToken: ${CSRF}" \
    -F "content=vztmpl" \
    -F "filename=@${CACHE_DIR}/${ALPINE_TEMPLATE}" \
    "${PROXMOX_URL}/api2/json/nodes/matryoshka/storage/local/upload"
  echo

  echo "==> Uploading OPNsense ISO"
  curl -sk --max-time 1800 -X POST \
    -b "PVEAuthCookie=${TICKET}" \
    -H "CSRFPreventionToken: ${CSRF}" \
    -F "content=iso" \
    -F "filename=@${CACHE_DIR}/OPNsense-25.1-dvd-amd64.iso" \
    "${PROXMOX_URL}/api2/json/nodes/matryoshka/storage/local/upload"
  echo

  echo "==> Upload complete"
}

case "${1:-}" in
  download) download ;;
  upload)   shift; upload "$@" ;;
  *)
    echo "Usage: $0 {download|upload <host:port>}"
    exit 1
    ;;
esac
