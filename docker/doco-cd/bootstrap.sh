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
)

function usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Bootstrap doco-cd on the current host.

Options:
  --age-key <key>     SOPS age key value (saved to ${SCRIPT_DIR}/.age.key)
  --token <value>     GitHub access token (saved to ${SCRIPT_DIR}/.env)
  -h, --help          Show this help message

On first run, both --age-key and --token are required.
On subsequent runs, saved credentials are reused automatically.
EOF
    exit 0
}

function parse_args() {
    AGE_KEY=""
    GIT_TOKEN=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --age-key)
                AGE_KEY="${2:?--age-key requires a value}"
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

function setup_age_key() {
    local target="${SCRIPT_DIR}/.age.key"

    if [[ -n "${AGE_KEY}" ]]; then
        echo "${AGE_KEY}" >"${target}"
        log info "Saved age key" "path=${target}"
    elif [[ ! -f "${target}" ]]; then
        log error "Age key not found at ${target}, provide it with --age-key <key>"
    else
        log debug "Age key already exists" "path=${target}"
    fi
}

function setup_env() {
    local target="${SCRIPT_DIR}/.env"

    if [[ -n "${GIT_TOKEN}" ]]; then
        echo "GIT_ACCESS_TOKEN=${GIT_TOKEN}" >"${target}"
        log info "Saved git access token" "path=${target}"
    elif [[ ! -f "${target}" ]]; then
        log error "Env file not found at ${target}, provide the token with --token <value>"
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

    setup_age_key
    setup_env

    log info "Starting doco-cd" "profile=${profile}"
    docker compose --project-directory "${SCRIPT_DIR}" --profile "${profile}" up -d

    log info "Bootstrap complete"
}

main "$@"
