#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env from repo root
source "$ROOT_DIR/.env"

# Resolve bws:// references in vault.yaml using bws-inject
EXTRA_VARS=()
echo "Resolving secrets from Bitwarden Secrets Manager..."
if RESOLVED_VAULT=$(cat "$SCRIPT_DIR/vars/vault.yaml" | "$ROOT_DIR/scripts/bws-inject" 2>&1); then
  # Inject BWS_ACCESS_TOKEN from .env (not stored in BWS itself)
  RESOLVED_VAULT="${RESOLVED_VAULT//BWS_ACCESS_TOKEN_PLACEHOLDER/$BWS_ACCESS_TOKEN}"

  TMPFILE=$(mktemp)
  trap 'rm -f "$TMPFILE"' EXIT
  echo "$RESOLVED_VAULT" > "$TMPFILE"
  EXTRA_VARS+=("-e" "@$TMPFILE")
else
  echo "WARNING: BWS fetch failed, running without secrets (skipping secret-dependent tasks)"
  EXTRA_VARS+=("--skip-tags" "secrets")
fi

# Run ansible-playbook
cd "$SCRIPT_DIR"
ansible-playbook playbooks/vyos.yaml \
  "${EXTRA_VARS[@]}" \
  "$@"
