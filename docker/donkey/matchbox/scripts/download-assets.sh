#!/bin/bash
set -euo pipefail

# https://factory.talos.dev/?arch=amd64&bootloader=auto&cmdline-set=true&extensions=-&extensions=siderolabs%2Fi915&extensions=siderolabs%2Fintel-ucode&extensions=siderolabs%2Fiscsi-tools&extensions=siderolabs%2Fmei&extensions=siderolabs%2Fnfsrahead&extensions=siderolabs%2Fnut-client&extensions=siderolabs%2Fnvme-cli&extensions=siderolabs%2Futil-linux-tools&platform=metal&target=metal&version=1.12.1
SCHEMATIC_ID="26034a8501cbcbc2a9788b3e5b74c04ceae8637e07b4a8075a1f41f5e0579615"
# renovate: datasource=docker depName=ghcr.io/siderolabs/installer
VERSION="v1.12.1"

ASSETS_DIR="/assets"

mkdir -p "$ASSETS_DIR/talos"

# Check TALOS_VERSION.txt
if [ -f "$ASSETS_DIR/talos/TALOS_VERSION.txt" ]; then
  FILE_VERSION=$(cat "$ASSETS_DIR/talos/TALOS_VERSION.txt")
else
  FILE_VERSION="N/A"
fi

if [ "$VERSION" = "$FILE_VERSION" ]; then
  echo "Talos assets already downloaded for version ($VERSION)"
else
  echo "Downloading Talos assets for version $VERSION..."
  curl -L -o "$ASSETS_DIR/talos/kernel-amd64" "https://factory.talos.dev/image/$SCHEMATIC_ID/$VERSION/kernel-amd64"
  curl -L -o "$ASSETS_DIR/talos/kernel-arm64" "https://factory.talos.dev/image/$SCHEMATIC_ID/$VERSION/kernel-arm64"
  curl -L -o "$ASSETS_DIR/talos/initramfs-amd64.xz" "https://factory.talos.dev/image/$SCHEMATIC_ID/$VERSION/initramfs-amd64.xz"
  curl -L -o "$ASSETS_DIR/talos/initramfs-arm64.xz" "https://factory.talos.dev/image/$SCHEMATIC_ID/$VERSION/initramfs-arm64.xz"
  echo "$VERSION" > "$ASSETS_DIR/talos/TALOS_VERSION.txt"
fi

# iPXE assets
if [ -f "$ASSETS_DIR/ipxe.efi" ] && [ -f "$ASSETS_DIR/undionly.kpxe" ]; then
  echo "iPXE assets already present."
else
  echo "Downloading iPXE assets..."
  curl -L -o "$ASSETS_DIR/ipxe.efi" "https://boot.ipxe.org/ipxe.efi"
  curl -L -o "$ASSETS_DIR/undionly.kpxe" "https://boot.ipxe.org/undionly.kpxe"
fi

echo "Asset download completed."
