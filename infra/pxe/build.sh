#!/usr/bin/env bash
set -Eeuo pipefail

# Build custom iPXE EFI binary with embedded menu script.
# Outputs ipxe.efi to infra/.cache/
#
# ⚠️ Builds snponly.efi, not ipxe.efi. snponly uses the UEFI firmware's own
# Simple Network Protocol driver for the NIC it booted from; plain ipxe.efi uses
# iPXE's native drivers. On charmander (HP EliteDesk 800 G4) the native driver
# never brings the link up - "Waiting for link-up on net0... Down" - even though
# firmware PXE had just TFTP'd the binary over that same NIC. Every machine here
# does firmware PXE correctly, so SNP is the more compatible choice.
# The output is still named ipxe.efi so DHCP's boot-file-name is unchanged.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../.cache"
MENU_SCRIPT="${SCRIPT_DIR}/menu.ipxe"

mkdir -p "$CACHE_DIR"

echo "==> Building custom iPXE with embedded menu..."
docker run --rm \
  --platform linux/amd64 \
  -v "${MENU_SCRIPT}:/embed.ipxe:ro" \
  -v "${CACHE_DIR}:/output" \
  ubuntu:24.04 bash -c '
    apt-get update -qq
    apt-get install -y -qq git gcc make liblzma-dev mtools isolinux gcc-x86-64-linux-gnu > /dev/null
    git clone --depth 1 https://github.com/ipxe/ipxe.git /build
    cd /build/src
    make bin-x86_64-efi/snponly.efi EMBED=/embed.ipxe NO_WERROR=1 2>&1 | tail -5
    cp bin-x86_64-efi/snponly.efi /output/ipxe.efi
  '

echo "==> Built: ${CACHE_DIR}/ipxe.efi"
ls -lh "${CACHE_DIR}/ipxe.efi"
