#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env from repo root
source "$ROOT_DIR/.env"

# Resolve bws:// references in vault.yaml using bws-inject
echo "Resolving secrets from Bitwarden Secrets Manager..."
RESOLVED_VAULT=$(cat "$SCRIPT_DIR/vars/vault.yaml" | "$ROOT_DIR/scripts/bws-inject")

# Inject BWS_ACCESS_TOKEN from .env (not stored in BWS itself)
RESOLVED_VAULT="${RESOLVED_VAULT//BWS_ACCESS_TOKEN_PLACEHOLDER/$BWS_ACCESS_TOKEN}"

# Write resolved vars to a temp file
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
echo "$RESOLVED_VAULT" > "$TMPFILE"

# Run ansible-playbook with resolved secrets
cd "$SCRIPT_DIR"
cd "$SCRIPT_DIR"
ansible-playbook playbooks/vyos.yaml \
  -e "@$TMPFILE" \
  "$@"
