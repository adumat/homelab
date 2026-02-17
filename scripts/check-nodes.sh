#!/usr/bin/env bash
# Check node health: ping, Talos API, and Kubernetes status
# Reads node IPs from talconfig.yaml + extra hosts
# Polls continuously and updates in-place (Ctrl+C to stop)

POLL_INTERVAL="${1:-10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALCONFIG="$SCRIPT_DIR/../kubernetes/talos/talconfig.yaml"

if [[ ! -f "$TALCONFIG" ]]; then
  echo "talconfig.yaml not found at $TALCONFIG"
  exit 1
fi

# Parse hostname/IP/role from talconfig (skip commented-out nodes)
mapfile -t talos_nodes < <(
  awk '
    /^[[:space:]]*#/ { next }
    /hostname:/ { gsub(/["'"'"']/, ""); host=$NF }
    /ipAddress:/ { gsub(/["'"'"']/, ""); ip=$NF }
    /controlPlane:/ { cp=$NF; if (host && ip) print host ":" ip ":" cp; host=""; ip=""; cp="" }
  ' "$TALCONFIG"
)

# Extra hosts to monitor (not Talos nodes)
extra_hosts=(
  "donkey:donkey.lan"
  "elizabeth:elizabeth.lan"
)

# Total lines to redraw (pool + header + nodes + blank + header + hosts)
total_lines=$(( 2 + ${#talos_nodes[@]} + 1 + 1 + ${#extra_hosts[@]} ))

check_talos_node() {
  local name="$1" ip="$2" role="$3"
  [[ "$role" == "true" ]] && label="control-plane" || label="worker"

  local prefix
  prefix=$(printf "%-14s %-18s %-16s" "$name" "($ip)" "[$label]")

  # Ping check (fast gate)
  if ! ping -c1 -W1 "$ip" &>/dev/null; then
    printf "%s  \e[31m[DOWN]\e[0m ping=FAIL\e[K\n" "$prefix"
    return
  fi

  # Talos API check (only if ping succeeds, with timeout)
  local talos_out talos_ver talos_stage
  talos_out=$(timeout 5 talosctl version -n "$ip" --short 2>/dev/null || true)
  if echo "$talos_out" | grep -q 'Tag:'; then
    talos_ver=$(echo "$talos_out" | awk '/Tag:/ {print $2; exit}')
  else
    talos_ver=""
  fi

  # Talos machine stage (running, maintenance, booting, etc.)
  talos_stage=$(timeout 5 talosctl -n "$ip" get machinestatus -o yaml 2>/dev/null \
    | awk '/stage:/ {print $2; exit}')
  talos_stage="${talos_stage:-unknown}"

  # Kubernetes node status (match by hostname since IP column varies)
  local k8s_state="NotFound"
  if [[ -n "$k8s_status" ]]; then
    local k8s_line
    k8s_line=$(echo "$k8s_status" | awk -v name="$name" '$1 == name {print}')
    if [[ -n "$k8s_line" ]]; then
      k8s_state=$(echo "$k8s_line" | awk '{print $2}')
    fi
  fi

  # Summary
  if [[ -n "$talos_ver" && "$talos_stage" == "running" && "$k8s_state" == "Ready" ]]; then
    printf "%s  \e[32m[ OK ]\e[0m ping=ok  talos=%s (%s)  k8s=%s\e[K\n" "$prefix" "$talos_ver" "$talos_stage" "$k8s_state"
  else
    printf "%s  \e[33m[WARN]\e[0m ping=ok" "$prefix"
    [[ -n "$talos_ver" ]] && printf "  talos=%s (%s)" "$talos_ver" "$talos_stage" || printf "  talos=UNREACHABLE"
    printf "  k8s=%s\e[K\n" "$k8s_state"
  fi
}

check_host() {
  local name="$1" host="$2"
  local prefix
  prefix=$(printf "%-14s %-18s %-16s" "$name" "($host)" "[host]")

  if ping -c1 -W1 "$host" &>/dev/null; then
    printf "%s  \e[32m[ OK ]\e[0m ping=ok\e[K\n" "$prefix"
  else
    printf "%s  \e[31m[DOWN]\e[0m ping=FAIL\e[K\n" "$prefix"
  fi
}

# Hide cursor, restore on exit
trap 'tput cnorm; echo; exit 0' INT TERM
tput civis

first_run=true
while true; do
  # Move cursor back to top (except first run)
  if [[ "$first_run" == true ]]; then
    first_run=false
  else
    printf "\e[%dA" "$total_lines"
  fi

  # Get k8s node statuses in one call (may fail if cluster is down)
  k8s_status=$(timeout 5 kubectl get nodes -o wide --no-headers 2>/dev/null || true)

  printf "Polling every %ss — %s\e[K\n" "$POLL_INTERVAL" "$(date '+%H:%M:%S')"
  printf "\e[1m=== Talos Nodes ===\e[0m\e[K\n"
  for entry in "${talos_nodes[@]}"; do
    name="${entry%%:*}"
    rest="${entry#*:}"
    ip="${rest%%:*}"
    role="${rest##*:}"
    check_talos_node "$name" "$ip" "$role"
  done

  printf "\e[K\n"
  printf "\e[1m=== Other Hosts ===\e[0m\e[K\n"
  for entry in "${extra_hosts[@]}"; do
    name="${entry%%:*}"
    host="${entry##*:}"
    check_host "$name" "$host"
  done

  sleep "$POLL_INTERVAL"
done
