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
    hostname="$(hostname -s)"

    if [[ -v HOST_PROFILES["${hostname}"] ]]; then
        echo "${HOST_PROFILES["${hostname}"]}"
        return
    fi

    log error "Unknown hostname '${hostname}', expected one of: ${!HOST_PROFILES[*]}"
}

function setup_env() {
    local target="${SCRIPT_DIR}/.env"

    if [[ -n "${GIT_TOKEN}" || -n "${BWS_TOKEN}" ]]; then
        # Build env file with provided values, preserving existing ones
        local git_val="${GIT_TOKEN}" bws_val="${BWS_TOKEN}"

        if [[ -f "${target}" ]]; then
            [[ -z "${git_val}" ]] && git_val=$(grep -oP '^GIT_ACCESS_TOKEN=\K.*' "${target}" 2>/dev/null || true)
            [[ -z "${bws_val}" ]] && bws_val=$(grep -oP '^BWS_ACCESS_TOKEN=\K.*' "${target}" 2>/dev/null || true)
        fi

        cat >"${target}" <<EOF
GIT_ACCESS_TOKEN=${git_val}
BWS_ACCESS_TOKEN=${bws_val}
EOF
        log info "Saved credentials" "path=${target}"
    elif [[ ! -f "${target}" ]]; then
        log error "Env file not found at ${target}, provide credentials with --token and --bws-token"
    else
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
