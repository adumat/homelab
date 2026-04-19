#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap navi LXC: install SSH + Docker, deploy doco-cd + matchbox, upload iPXE.
# Run once after tofu creates the LXC.
#
# Usage: ./bootstrap-navi.sh
# Requires: bws CLI (via mise), BWS_ACCESS_TOKEN in .env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$ROOT_DIR/.env"

PVE_HOST="10.1.10.9"
NAVI_HOST="10.1.10.5"
GLADOS_HOST="glados.lan"
LXC_ID=101

GIT_TOKEN=$(bws secret get "71565302-6fb5-42ea-b1be-b427015bfe26" | jq -r '.value') # gitleaks:allow
NAVI_PASS=$(bws secret get "2ec0b6fd-7314-4f10-82ca-b42f00843aee" | jq -r '.value') # gitleaks:allow

PVE_PASS=$(bws secret get "f26804d7-0421-4fc5-8902-b42e0076c953" | jq -r '.value | fromjson | .password') # gitleaks:allow

pve() { sshpass -p "${PVE_PASS}" ssh -o PubkeyAuthentication=no "root@${PVE_HOST}" "pct exec ${LXC_ID} -- sh -c \"$*\""; }
NAVI_SSH="sshpass -p ${NAVI_PASS} ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no"
NAVI_SCP="sshpass -p ${NAVI_PASS} scp -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no"
run() { ${NAVI_SSH} "root@${NAVI_HOST}" "$@"; }
glados() { ssh "root@${GLADOS_HOST}" "$@"; }

# Remove old host key (LXC recreated = new key)
ssh-keygen -R "${NAVI_HOST}" 2>/dev/null || true

echo "==> Installing SSH on navi via Proxmox"
pve "apk add openssh"
pve "ssh-keygen -A"
pve "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config"
pve "echo root:${NAVI_PASS} | chpasswd"
pve "rc-update add sshd default"
pve "service sshd restart"

echo "==> Installing Docker + dependencies"
run "apk update && apk add docker docker-compose bash curl jq"
run "rc-update add docker default && service docker start"
run "docker --version && docker compose version"

echo "==> Uploading doco-cd files"
run "mkdir -p /opt/homelab/docker/doco-cd /opt/homelab/scripts/lib"
${NAVI_SCP} -r "$ROOT_DIR/docker/doco-cd/." "root@${NAVI_HOST}:/opt/homelab/docker/doco-cd/"
${NAVI_SCP} "$ROOT_DIR/scripts/lib/common.sh" "root@${NAVI_HOST}:/opt/homelab/scripts/lib/common.sh"

echo "==> Running doco-cd bootstrap"
run "cd /opt/homelab/docker/doco-cd && bash bootstrap.sh --token ${GIT_TOKEN} --bws-token ${BWS_ACCESS_TOKEN}"

echo "==> Uploading custom iPXE to glados (OPNsense TFTP)"
IPXE_EFI="${SCRIPT_DIR}/../.cache/ipxe.efi"
if [ ! -f "${IPXE_EFI}" ]; then
  echo "    ${IPXE_EFI} not found. Run infra/pxe/build.sh first." >&2
  exit 1
fi
glados "mkdir -p /usr/local/tftp"
scp "${IPXE_EFI}" "root@${GLADOS_HOST}:/usr/local/tftp/ipxe.efi"
echo "    ipxe.efi uploaded"

echo "==> Done."
