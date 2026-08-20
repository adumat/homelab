#!/usr/bin/env bash
# Audit backup coverage: every PVC is either backed up by kopiur or declared an
# exception in backup-policy.yaml, and every claim of protection is real.
#
# The point is not to list what is backed up - `kubectl get snapshotpolicy` does
# that. It is to catch the two failure modes that look like success:
#
#   1. a PVC nobody ever thought about        (paperless-ai: 4 months, no backup)
#   2. a policy that exists but never SUCCEEDS (romm: 2 days of PermissionDenied
#      while the SnapshotPolicy sat there looking healthy)
#
# "Protected" is derived from the live SnapshotPolicy objects, never from the
# policy file, so the two cannot disagree about what is backed up.
#
# Exit 0 = clean, 1 = findings. Safe to run any time; reads only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="${BACKUP_POLICY:-$SCRIPT_DIR/../backup-policy.yaml}"
# How stale a protected volume's newest successful snapshot may be. Schedules are
# daily, so 48h tolerates one missed night without crying wolf.
MAX_AGE_HOURS="${MAX_AGE_HOURS:-48}"

K() { mise exec -- kubectl "$@"; }
Y() { mise exec -- yq "$@"; }
J() { mise exec -- jq "$@"; }

RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; RST=$'\e[0m'
findings=0
warnings=0

[[ -f "$POLICY" ]] || { echo "${RED}backup-policy.yaml not found at $POLICY${RST}"; exit 1; }
K get ns kube-system >/dev/null 2>&1 || {
  # A failing kubectl would otherwise read as "no PVCs exist" and pass silently.
  echo "${RED}no cluster connectivity - refusing to report a clean audit${RST}"; exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- live state -------------------------------------------------------------
K get pvc -A -o json 2>/dev/null \
  | J -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | sort > "$tmp/pvcs"

# A SnapshotPolicy names the PVCs it backs up in spec.sources[].pvc.name, in its
# own namespace. That mapping - not the policy file - defines "protected".
K get snapshotpolicy -A -o json 2>/dev/null \
  | J -r '.items[] | .metadata.namespace as $ns | .metadata.name as $pol
          | .spec.sources[]?.pvc.name // empty | "\($ns)/\(.) \($ns)/\($pol)"' \
  | sort > "$tmp/policy_map"
cut -d' ' -f1 "$tmp/policy_map" | sort -u > "$tmp/protected"

# NOTE: `// empty` is jq syntax and yq rejects it ("lexer: invalid input text").
# Do NOT add 2>/dev/null here - suppressing it once made every exception parse as
# empty, and the audit then reported 28 confident false findings. A parse error
# must be loud, because a silently empty policy file is indistinguishable from
# "nothing is declared" and this whole check inverts.
for kind in external disposable temporary; do
  Y -r ".${kind}[]?.pvc" "$POLICY" | sort > "$tmp/$kind" || {
    echo "${RED}failed to parse .${kind} from $POLICY${RST}"; exit 1
  }
done
cat "$tmp/external" "$tmp/disposable" "$tmp/temporary" | sort > "$tmp/declared"
# A policy file that parses to nothing while clearly having content is the bug
# above, not a legitimately empty exception list.
if [[ ! -s "$tmp/declared" ]] && grep -qE '^\s+- pvc:' "$POLICY"; then
  echo "${RED}$POLICY lists PVCs but none parsed - check the yq expressions${RST}"; exit 1
fi

echo
echo "  ${DIM}policy: $POLICY${RST}"
printf '  %s%d live PVCs · %d protected by kopiur · %d declared exceptions%s\n' \
  "$DIM" "$(grep -c . "$tmp/pvcs")" "$(grep -c . "$tmp/protected")" "$(grep -c . "$tmp/declared")" "$RST"

# --- 1. unclassified: the paperless-ai failure mode --------------------------
echo
echo "  UNCLASSIFIED (neither backed up nor declared)"
if unc=$(comm -23 "$tmp/pvcs" <(cat "$tmp/protected" "$tmp/declared" | sort -u)) && [[ -n "$unc" ]]; then
  while read -r p; do
    [[ -z "$p" ]] && continue
    echo "    ${RED}✗${RST} $p"
    findings=$((findings + 1))
  done <<< "$unc"
else
  echo "    ${GRN}✓${RST} none"
fi

# --- 2. protection that is not real: the romm failure mode -------------------
echo
echo "  PROTECTED BUT NOT PRODUCING (policy exists, backups are not landing)"
now=$(date -u +%s)
bad=0
while read -r pvc pol; do
  [[ -z "$pvc" ]] && continue
  ns="${pol%%/*}"; polname="${pol##*/}"
  # Only snapshots this policy produced. Discovered ones belong to decommissioned
  # apps and would otherwise make a dead policy look alive.
  newest=$(K get snapshots.kopiur.home-operations.com -n "$ns" -o json 2>/dev/null | J -r \
    --arg pol "$polname" '[.items[]
      | select(.spec.policyRef.name == $pol)
      | select((.status.origin // "") != "discovered")]
      | sort_by(.metadata.creationTimestamp) | last
      | if . == null then "NONE" else "\(.status.phase) \(.metadata.creationTimestamp)" end')
  phase="${newest%% *}"; ts="${newest##* }"
  case "$phase" in
    NONE)
      echo "    ${RED}✗${RST} $pvc ${DIM}(policy $pol has never produced a snapshot)${RST}"
      findings=$((findings + 1)); bad=1 ;;
    Succeeded)
      # macOS date needs -j -f; this script is run from the laptop.
      then_s=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${ts%%.*}Z" +%s 2>/dev/null \
               || date -u -d "$ts" +%s 2>/dev/null || echo 0)
      if [[ "$then_s" != 0 ]]; then
        age_h=$(( (now - then_s) / 3600 ))
        if (( age_h > MAX_AGE_HOURS )); then
          echo "    ${RED}✗${RST} $pvc ${DIM}(newest success is ${age_h}h old, limit ${MAX_AGE_HOURS}h)${RST}"
          findings=$((findings + 1)); bad=1
        fi
      fi ;;
    *)
      echo "    ${RED}✗${RST} $pvc ${DIM}(newest snapshot is $phase)${RST}"
      findings=$((findings + 1)); bad=1 ;;
  esac
done < "$tmp/policy_map"
(( bad == 0 )) && echo "    ${GRN}✓${RST} none"

# --- 3. contradictions and stale entries ------------------------------------
echo
echo "  POLICY FILE DISAGREES WITH THE CLUSTER"
dis=0
# Declared an exception, yet something is backing it up. Harmless but it means
# the stated intent is wrong, and intent is the whole value of the file.
while read -r p; do
  [[ -z "$p" ]] && continue
  if grep -qx "$p" "$tmp/protected"; then
    echo "    ${YEL}!${RST} $p ${DIM}is declared an exception but a SnapshotPolicy backs it up${RST}"
    warnings=$((warnings + 1)); dis=1
  fi
done < "$tmp/declared"
# Listed in the file but gone from the cluster - delete the entry.
while read -r p; do
  [[ -z "$p" ]] && continue
  if ! grep -qx "$p" "$tmp/pvcs"; then
    echo "    ${YEL}!${RST} $p ${DIM}is declared but no longer exists - remove it from the policy${RST}"
    warnings=$((warnings + 1)); dis=1
  fi
done < "$tmp/declared"
# A policy pointing at a PVC that is not there backs up nothing at all.
while read -r pvc pol; do
  [[ -z "$pvc" ]] && continue
  if ! grep -qx "$pvc" "$tmp/pvcs"; then
    echo "    ${RED}✗${RST} $pol ${DIM}names $pvc, which does not exist${RST}"
    findings=$((findings + 1)); dis=1
  fi
done < "$tmp/policy_map"
(( dis == 0 )) && echo "    ${GRN}✓${RST} none"

# --- 4. reminders -----------------------------------------------------------
if [[ -s "$tmp/temporary" ]]; then
  echo
  echo "  TEMPORARY (reminders, not failures)"
  while read -r p; do
    [[ -z "$p" ]] && continue
    reason=$(Y -r ".temporary[] | select(.pvc == \"$p\") | .reason // \"-\"" "$POLICY" 2>/dev/null)
    echo "    ${DIM}·${RST} $p ${DIM}— $reason${RST}"
  done < "$tmp/temporary"
fi

echo
if (( findings > 0 )); then
  echo "  ${RED}${findings} finding(s)${RST}${warnings:+, ${YEL}${warnings} warning(s)${RST}}"
  exit 1
fi
if (( warnings > 0 )); then
  echo "  ${GRN}no findings${RST}, ${YEL}${warnings} warning(s)${RST}"
  exit 0
fi
echo "  ${GRN}clean: every PVC is either backed up or declared, and every policy is producing${RST}"
