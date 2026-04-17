#!/usr/bin/env bash
set -Eeuo pipefail

# Build custom iPXE EFI binary with embedded menu script.
# Outputs ipxe.efi to infra/.cache/

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
    make bin-x86_64-efi/ipxe.efi EMBED=/embed.ipxe NO_WERROR=1 2>&1 | tail -5
    cp bin-x86_64-efi/ipxe.efi /output/ipxe.efi
  '

echo "==> Built: ${CACHE_DIR}/ipxe.efi"
ls -lh "${CACHE_DIR}/ipxe.efi"
