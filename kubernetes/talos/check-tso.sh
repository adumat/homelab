#!/usr/bin/env bash
# Check TSO (tx-tcp-segmentation) status on all nodes
# Reads node IPs from talconfig.yaml, detects e1000e interfaces automatically

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALCONFIG="$SCRIPT_DIR/talconfig.yaml"

if [[ ! -f "$TALCONFIG" ]]; then
  echo "talconfig.yaml not found at $TALCONFIG"
  exit 1
fi

# Parse hostname/IP pairs from talconfig (skip commented-out nodes)
mapfile -t nodes < <(
  awk '
    /^[[:space:]]*#/ { next }
    /hostname:/ { gsub(/["'"'"']/, ""); host=$NF }
    /ipAddress:/ { gsub(/["'"'"']/, ""); if (host) print host ":" $NF }
  ' "$TALCONFIG"
)

for entry in "${nodes[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"

  echo "--- $name ($ip) ---"

  # Get all link statuses and extract interface id + driver
  links=$(talosctl get links -n "$ip" -o yaml 2>/dev/null)
  if [[ -z "$links" ]]; then
    echo "  [ERR ] unable to query node"
    echo
    continue
  fi

  # Parse each link: extract id and driver pairs
  mapfile -t ifaces < <(
    echo "$links" | awk '
      /^metadata:/ { in_meta=1; in_spec=0 }
      /^spec:/ { in_meta=0; in_spec=1 }
      in_meta && /id:/ { id=$2 }
      in_spec && /driver:/ { print id ":" $2 }
    '
  )

  found=false
  for iface in "${ifaces[@]}"; do
    iface_name="${iface%%:*}"
    driver="${iface##*:}"

    if [[ "$driver" == "e1000e" ]]; then
      found=true
      tso=$(talosctl get ethernetstatus "$iface_name" -n "$ip" -o yaml 2>/dev/null \
        | awk '/tx-tcp-segmentation:/ { print $2; exit }')

      if [[ "$tso" == *"on"* ]]; then
        echo "  [WARN] $iface_name (driver: e1000e) — TSO enabled (should be disabled)"
      elif [[ "$tso" == *"off"* ]]; then
        echo "  [ OK ] $iface_name (driver: e1000e) — TSO disabled"
      else
        echo "  [ERR ] $iface_name (driver: e1000e) — unable to read TSO state"
      fi
    fi
  done

  if [[ "$found" == false ]]; then
    echo "  [ -- ] no e1000e interfaces found"
  fi
  echo
done
