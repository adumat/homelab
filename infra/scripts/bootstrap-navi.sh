#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap navi LXC: install Docker, copy doco-cd files, run bootstrap.
# Run once after tofu creates the LXC.
#
# Usage: ./bootstrap-navi.sh <navi-ip> <glados-ip> [--token <git-token>] [--bws-token <bws-token>]
# Example: ./bootstrap-navi.sh 10.1.10.5 10.1.1.1 --token ghp_xxx --bws-token 0.xxx

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAVI_HOST="${1:?Usage: $0 <navi-ip> <glados-ip> [--token <git-token>] [--bws-token <bws-token>]}"
GLADOS_HOST="${2:?Usage: $0 <navi-ip> <glados-ip> [--token <git-token>] [--bws-token <bws-token>]}"
shift 2

run() { ssh "root@${NAVI_HOST}" "$@"; }
glados() { ssh "root@${GLADOS_HOST}" "$@"; }

echo "==> Installing Docker + dependencies"
run "apk update && apk add docker docker-compose bash curl jq"
run "rc-update add docker default && service docker start"
run "docker --version && docker compose version"

echo "==> Uploading doco-cd files"
# Replicate the repo structure so bootstrap.sh relative paths work
run "mkdir -p /opt/homelab/docker/doco-cd /opt/homelab/scripts/lib"
scp -r "$ROOT_DIR/docker/doco-cd/." "root@${NAVI_HOST}:/opt/homelab/docker/doco-cd/"
scp "$ROOT_DIR/scripts/lib/common.sh" "root@${NAVI_HOST}:/opt/homelab/scripts/lib/common.sh"

echo "==> Running doco-cd bootstrap"
run "cd /opt/homelab/docker/doco-cd && bash bootstrap.sh $*"

echo "==> Uploading iPXE files to glados (OPNsense TFTP)"
glados "mkdir -p /usr/local/tftp"
for file in ipxe.efi undionly.kpxe; do
  if [ ! -f "${SCRIPT_DIR}/../.cache/${file}" ]; then
    echo "    Downloading ${file}..."
    curl -sL -o "${SCRIPT_DIR}/../.cache/${file}" "https://boot.ipxe.org/${file}"
  fi
  scp "${SCRIPT_DIR}/../.cache/${file}" "root@${GLADOS_HOST}:/usr/local/tftp/${file}"
  echo "    ${file} uploaded"
done

echo "==> Done."
