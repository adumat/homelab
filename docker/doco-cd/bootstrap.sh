#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

# Map hostnames to doco-cd profiles
declare -A HOST_PROFILES=(
    [donkey]=donkey
    [elizabeth]=elizabeth
    [navi]=navi
)

function usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Bootstrap doco-cd on the current host.

Options:
  --bws-token <value>   Bitwarden Secrets Manager access token (saved to ${SCRIPT_DIR}/.env)
  --token <value>       GitHub access token (saved to ${SCRIPT_DIR}/.env)
  -h, --help            Show this help message

On first run, both --bws-token and --token are required.
On subsequent runs, saved credentials are reused automatically.
EOF
    exit 0
}

function parse_args() {
    BWS_TOKEN=""
    GIT_TOKEN=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bws-token)
                BWS_TOKEN="${2:?--bws-token requires a value}"
                shift 2
                ;;
            --token)
                GIT_TOKEN="${2:?--token requires a value}"
                shift 2
                ;;
            -h | --help)
                usage
                ;;
            *)
                log error "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

function detect_profile() {
    local hostname
    # Lowercased on purpose: Unraid reports a capitalised hostname ('Elizabeth'),
    # which does not match the lowercase keys in HOST_PROFILES. donkey and navi
    # are already lowercase, so this never surfaced until elizabeth was added.
    hostname="$(hostname -s | tr '[:upper:]' '[:lower:]')"

    if [[ -v HOST_PROFILES["${hostname}"] ]]; then
        echo "${HOST_PROFILES["${hostname}"]}"
        return
    fi

    log error "Unknown hostname '${hostname}', expected one of: ${!HOST_PROFILES[*]}"
}

# Read one KEY=value from an env file.
#
# ⚠️ NOT `grep -oP`: navi is a BusyBox LXC and BusyBox grep has no -P, so the
# pattern fails, `|| true` swallows the error, and the caller sees an empty
# value for a key that is actually set. Combined with the old unguarded write
# that is how navi ended up with BWS_ACCESS_TOKEN= and 4.5 days of doco-cd
# crash-looping on `invalid_client`. sed with a basic regex works on BusyBox,
# BSD and GNU alike.
function env_value() {
    local key="$1" file="$2"
    [[ -f "${file}" ]] || return 0
    sed -n "s/^${key}=//p" "${file}" | head -n1
}

function setup_env() {
    local target="${SCRIPT_DIR}/.env"

    if [[ -n "${GIT_TOKEN}" || -n "${BWS_TOKEN}" ]]; then
        # Build env file with provided values, preserving existing ones
        local git_val="${GIT_TOKEN}" bws_val="${BWS_TOKEN}"

        if [[ -f "${target}" ]]; then
            [[ -z "${git_val}" ]] && git_val=$(env_value GIT_ACCESS_TOKEN "${target}")
            [[ -z "${bws_val}" ]] && bws_val=$(env_value BWS_ACCESS_TOKEN "${target}")
        fi

        # Refuse to write a blank credential. Without this the fallback above
        # silently resolves an unset --bws-token to "", writes
        # BWS_ACCESS_TOKEN= and logs "Saved credentials" - and doco-cd then
        # crash-loops on `invalid_client` because it authenticates with an empty
        # secret. That cost navi 4.5 days of dead GitOps in 2026-08, found only
        # by reading container logs by hand. A bootstrap that cannot produce a
        # usable credential must fail loudly instead.
        [[ -z "${git_val}" ]] && log error "Refusing to write ${target}: GIT_ACCESS_TOKEN resolved empty. Pass --token, or run where the existing .env already has it."
        [[ -z "${bws_val}" ]] && log error "Refusing to write ${target}: BWS_ACCESS_TOKEN resolved empty. Pass --bws-token, or run where the existing .env already has it."

        cat >"${target}" <<EOF
GIT_ACCESS_TOKEN=${git_val}
BWS_ACCESS_TOKEN=${bws_val}
EOF
        log info "Saved credentials" "path=${target}"
    elif [[ ! -f "${target}" ]]; then
        log error "Env file not found at ${target}, provide credentials with --token and --bws-token"
    else
        # An existing file is not automatically a good one: this is the path a
        # re-run takes, and it is how navi stayed broken. Validate rather than
        # assume.
        local have_git have_bws
        have_git=$(env_value GIT_ACCESS_TOKEN "${target}")
        have_bws=$(env_value BWS_ACCESS_TOKEN "${target}")
        [[ -z "${have_git}" ]] && log error "${target} exists but GIT_ACCESS_TOKEN is empty. Re-run with --token."
        [[ -z "${have_bws}" ]] && log error "${target} exists but BWS_ACCESS_TOKEN is empty. Re-run with --bws-token."
        log debug "Env file already exists" "path=${target}"
    fi
}

function main() {
    parse_args "$@"

    local profile
    profile="$(detect_profile)"
    log info "Detected profile" "hostname=$(hostname -s)" "profile=${profile}"

    check_cli docker

    setup_env

    log info "Starting doco-cd" "profile=${profile}"
    docker compose --project-directory "${SCRIPT_DIR}" --profile "${profile}" up -d

    log info "Bootstrap complete"
}

main "$@"
