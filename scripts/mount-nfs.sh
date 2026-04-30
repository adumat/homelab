#!/usr/bin/env bash
# Mount/unmount NFS shares from elizabeth.lan to ./mnt/<name>
#
# Usage:
#   mount-nfs.sh mount <name>
#   mount-nfs.sh unmount <name>
#   mount-nfs.sh unmount-all
#   mount-nfs.sh list

set -eu -o pipefail

NFS_SERVER="elizabeth.lan"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MNT_ROOT="$REPO_ROOT/mnt"

declare -A SHARES=(
  [media]="/mnt/user/media"
  [recordings]="/mnt/user/recordings"
  [backups]="/mnt/user/backups"
  [immich]="/mnt/user/immich"
  [cloud]="/mnt/user/cloud"
)

usage() {
  cat <<EOF
Usage:
  $(basename "$0") mount <name>
  $(basename "$0") unmount <name>
  $(basename "$0") unmount-all
  $(basename "$0") list

Available shares:
$(for k in "${!SHARES[@]}"; do printf "  %-12s %s\n" "$k" "${SHARES[$k]}"; done | sort)
EOF
}

is_mounted() {
  mount | grep -q " on $1 "
}

cmd_mount() {
  local name="$1"
  local export="${SHARES[$name]:-}"
  if [[ -z "$export" ]]; then
    echo "Unknown share: $name" >&2
    usage >&2
    exit 1
  fi

  local target="$MNT_ROOT/$name"
  if [[ ! -d "$target" ]]; then
    if [[ -n "${SUDO_USER:-}" ]]; then
      sudo -u "$SUDO_USER" mkdir -p "$target"
    else
      mkdir -p "$target"
    fi
  fi

  if is_mounted "$target"; then
    echo "Already mounted: $target"
    return 0
  fi

  echo "Mounting $NFS_SERVER:$export -> $target"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    mount -t nfs -o resvport,rw,nolocks,locallocks "$NFS_SERVER:$export" "$target"
  else
    mount -t nfs "$NFS_SERVER:$export" "$target"
  fi
  echo "OK"
}

cmd_unmount() {
  local name="$1"
  local target="$MNT_ROOT/$name"

  if ! is_mounted "$target"; then
    echo "Not mounted: $target"
    return 0
  fi

  echo "Unmounting $target"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    umount -f "$target"
  else
    umount -l "$target"
  fi
  echo "OK"
}

cmd_unmount_all() {
  local any=0
  for target in "$MNT_ROOT"/*; do
    [[ -d "$target" ]] || continue
    if is_mounted "$target"; then
      any=1
      echo "Force unmounting $target"
      if [[ "$(uname -s)" == "Darwin" ]]; then
        umount -f "$target" || true
      else
        umount -l "$target" || true
      fi
    fi
  done
  if [[ $any -eq 0 ]]; then
    echo "Nothing mounted under $MNT_ROOT"
  fi
}

cmd_list() {
  printf "%-12s %-40s %s\n" "NAME" "EXPORT" "STATUS"
  for k in $(echo "${!SHARES[@]}" | tr ' ' '\n' | sort); do
    local target="$MNT_ROOT/$k"
    local status="not mounted"
    if is_mounted "$target"; then
      status="mounted"
    fi
    printf "%-12s %-40s %s\n" "$k" "${SHARES[$k]}" "$status"
  done
}

case "${1:-}" in
  mount)        [[ $# -eq 2 ]] || { usage >&2; exit 1; }; cmd_mount "$2" ;;
  unmount)      [[ $# -eq 2 ]] || { usage >&2; exit 1; }; cmd_unmount "$2" ;;
  unmount-all)  cmd_unmount_all ;;
  list)         cmd_list ;;
  ""|-h|--help) usage ;;
  *)            usage >&2; exit 1 ;;
esac
