#!/usr/bin/env bash
# Cycle UPS output to hard-reset the whole rack, then wake what does not return on its own.
# Gated: refuses to run unless the cluster is already down and elizabeth is idle.
#
# The Eaton Ellipse ECO 650 has no load.off, no load.cycle, and both PowerShare outlets
# report switchable=no. `shutdown.return` is its only cycle primitive and it cuts
# EVERYTHING on the UPS. That is why the gates below exist.
#
#   ./scripts/ups-power-cycle.sh            # run the gates only (default)
#   ./scripts/ups-power-cycle.sh --dry-run  # gates + confirmation + verify every precondition
#   ./scripts/ups-power-cycle.sh --execute  # shut elizabeth down, then cycle UPS output
#   ./scripts/ups-power-cycle.sh --wake     # after the cycle: WOL whatever stayed off
#
# Node shutdown is NOT done here - the operator does it first. See
# infra/docs/rack-power-cycle.md
set -uo pipefail

VPN_NAME="${VPN_NAME:-matteos-mac}"
DONKEY_KEY="${DONKEY_KEY:-$HOME/.ssh/donkey}"
ELIZ_KEY="${ELIZ_KEY:-$HOME/.ssh/id_ed25519}"
DONKEY_IP=10.1.10.3
ELIZ_IP=10.1.10.2
# Both delays are measured from when the command is issued, so ups.delay.start must EXCEED
# ups.delay.shutdown or the UPS may never re-energise (NUT documents this for some devices).
# The load is therefore dead for (start - shutdown) seconds, not for `start` seconds.
OFF_DELAY="${OFF_DELAY:-60}"        # ups.delay.shutdown: grace before the cut, room to drop the VPN
DEAD_SECONDS="${DEAD_SECONDS:-60}"  # how long the load actually stays dead
ON_DELAY=$(( OFF_DELAY + DEAD_SECONDS ))

TALOS_NODES="10.1.10.10 10.1.10.11 10.1.10.12 10.1.10.21 10.1.10.23"
BOOTID_FILE="${TMPDIR:-/tmp}/ups-cycle-donkey-bootid"   # S5: proof the cut actually happened
ELIZ_STATE=unknown

# name=ip=mac, in wake order. elizabeth first: NFS must serve before its consumers boot.
WAKE_LIST="elizabeth=10.1.10.2=14:da:e9:4d:e7:65
bulbasaur=10.1.10.10=1c:69:7a:a5:93:fc
charmander=10.1.10.11=f8:b4:6a:a5:87:ed
magikarp=10.1.10.21=e8:6a:64:a4:89:ca
squirtle=10.1.10.12=e8:6a:64:f6:ff:af
snorlax=10.1.10.23=e8:6a:64:76:2a:18"

SSH_D="ssh -n -i $DONKEY_KEY -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@$DONKEY_IP"
SSH_E="ssh -n -i $ELIZ_KEY  -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@$ELIZ_IP"
T="mise exec -- talosctl"

die()  { printf '\n\033[1;31mGATE FAILED:\033[0m %s\n' "$*" >&2; exit 1; }
# For failures after elizabeth is already down - never say "GATE FAILED" then, it reads as
# "nothing was done" at exactly the moment that is untrue.
abort() { printf '\n\033[1;31mABORTED MID-SEQUENCE:\033[0m %s\n\033[1;31mSTATE: elizabeth is DOWN, the rack is STILL POWERED. Re-run with --execute (it will skip elizabeth).\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
up()   { /sbin/ping -c 2 -t 3 "$1" >/dev/null 2>&1; }

ups_var() { $SSH_D "docker exec nut-server upsc ups@localhost 2>/dev/null | awk -F': ' '/^$1:/{print \$2}'"; }

# Read the NUT admin password inside the container so it never reaches this terminal.
nut_admin() {
  $SSH_D "PW=\$(docker exec nut-server awk '/^\\[admin\\]/{f=1} f&&/password/{print \$3; exit}' /etc/nut/upsd.users)
          docker exec nut-server $1 -u admin -p \"\$PW\" ups@localhost"
}

gates() {
  step "GATES"

  [ "$(scutil --nc status "$VPN_NAME" 2>/dev/null | head -1)" = "Connected" ] \
    || die "VPN '$VPN_NAME' is not Connected - nothing below is reachable"
  ok "VPN connected"

  $SSH_D 'exit 0' 2>/dev/null || die "cannot ssh donkey ($DONKEY_IP)"
  ok "donkey reachable"
  $SSH_D 'command -v wakeonlan >/dev/null' 2>/dev/null \
    || die "donkey has no wakeonlan - it is the only thing that can wake the rack afterwards"
  ok "donkey can send WOL"
  if up "$ELIZ_IP"; then
    $SSH_E 'exit 0' 2>/dev/null || die "elizabeth answers ping but SSH fails - fix that first"
    ELIZ_STATE=up; ok "elizabeth reachable"
  else
    ELIZ_STATE=down; warn "elizabeth is already OFF - resume path, its shutdown will be skipped"
  fi

  # GATE 1 - a parity check MAY be in progress, but only if the Parity Check Tuning plugin
  # will resume it. With parityTuningRestart=0 a clean array stop ABORTS the check.
  # Skipped entirely when elizabeth is already off (resume path after a mid-sequence abort).
  local resync pos pct restart
  if [ "$ELIZ_STATE" = down ]; then
    warn "elizabeth already off - skipping its gates and its shutdown (resume path)"
  else
    resync=$($SSH_E 'mdcmd status 2>/dev/null | awk -F= "/^mdResync=/{print \$2}"' 2>/dev/null)
    case "$resync" in ''|*[!0-9]*) die "unparseable mdResync='$resync' from elizabeth";; esac
    if [ "$resync" = "0" ]; then
      ok "elizabeth: no parity check running"
    else
      pos=$($SSH_E 'mdcmd status 2>/dev/null | awk -F= "/^mdResyncPos=/{print \$2}"' 2>/dev/null)
      case "$pos" in ''|*[!0-9]*) die "unparseable mdResyncPos='$pos'";; esac
      pct=$(( pos * 100 / resync ))
      restart=$($SSH_E 'grep -oE "parityTuningRestart=\"[01]\"" /boot/config/plugins/parity.check.tuning/parity.check.tuning.cfg 2>/dev/null' 2>/dev/null | grep -oE '[01]')
      [ "$restart" = "1" ] || die "parity check at ${pct}% and parityTuningRestart='${restart:-unset}'.
       A clean array stop would ABORT it and lose ${pct}% (~28h to redo from zero).
       Enable it: Settings > Scheduler > Parity Check Tuning, then re-run."
      warn "parity check at ${pct}% - will RESUME on next array start (parityTuningRestart=1)"
      # S11: the resume needs the array to autostart, or it waits for a manual click forever.
      $SSH_E 'grep -qE "^startArray=\"?yes" /boot/config/disk.cfg' 2>/dev/null \
        && ok "elizabeth array autostart enabled (parity will resume unattended)" \
        || warn "array autostart NOT confirmed - the parity resume may wait for a manual array start"
    fi
  fi

  # GATE 2 - the cluster must already be down. A node still 'running' means the operator has
  # not shut it down, and cutting power would hard-kill a live node.
  # 'shutting down' is ACCEPTED: nodes routinely hang there because unmounting Ceph-backed
  # volumes blocks in the kernel once Ceph loses quorum. They are not serving anything.
  local live="" stage
  for ip in $TALOS_NODES; do
    if ! up "$ip"; then ok "$ip off"; continue; fi
    stage=$($T -n "$ip" get machinestatus -o json 2>/dev/null | mise exec -- jq -r '.spec.stage' 2>/dev/null)
    case "$stage" in
      "shutting down") warn "$ip answering but stage='shutting down' (hung on Ceph unmount - acceptable)" ;;
      "")              warn "$ip answering, Talos API silent - treating as not serving" ;;
      *)               live="$live $ip($stage)" ;;
    esac
  done
  [ -n "$live" ] && die "these nodes are still live:$live
       Shut them down first:  mise exec -- talosctl -n <ips> shutdown --force"
  ok "no Talos node is serving"

  # GATE 3 - cycling while on battery is a different, worse operation.
  local st
  st=$(ups_var 'ups.status')
  echo "$st" | grep -q OL || die "UPS is not on line power (ups.status: $st)"
  ok "UPS on line power (ups.status: $st)"
  echo "$st" | grep -q ALARM && warn "UPS reports ALARM: '$(ups_var 'ups.alarm')'
        IRREDUCIBLE RISK: a failing battery may decline to re-energise its output. If it
        does not come back, no NUT client survives to issue load.on and the house is dark."

  # GATE 4 - credentials. Setting the off-window doubles as the auth test, so a wrong
  # password fails HERE rather than after elizabeth is already down.
  local orig_start ds dstart
  orig_start=$(ups_var 'ups.delay.start')
  # S6: 20s is too tight - the SSH session can still be open when power cuts, hanging the
  # pipeline before the VPN teardown runs. 90s gives room to verify and tear down cleanly.
  nut_admin "upsrw -s ups.delay.shutdown=$OFF_DELAY" >/dev/null 2>&1 || warn "could not set ups.delay.shutdown"
  nut_admin "upsrw -s ups.delay.start=$ON_DELAY" >/dev/null 2>&1 \
    || die "could not set ups.delay.start - NUT admin credentials or upsrw failed. Nothing changed."
  # S4b: exit status 0 does NOT mean the driver kept the value - read it back.
  dstart=$(ups_var 'ups.delay.start'); ds=$(ups_var 'ups.delay.shutdown')
  [ "$dstart" = "$ON_DELAY" ] \
    || die "ups.delay.start read back as '$dstart', not ${ON_DELAY} - the driver coerced it.
       The UPS may not restart. (was '${orig_start}' before this run)"
  # S4c: NUT documents that on some devices ondelay MUST exceed offdelay or the load stays off.
  [ "$dstart" -gt "$ds" ] 2>/dev/null \
    || die "ups.delay.start ($dstart) must exceed ups.delay.shutdown ($ds) or this UPS may never re-energise"
  ok "delays verified: cuts ${ds}s after the command, returns at +${dstart}s (dead for $((dstart-ds))s)"

  $SSH_D 'docker exec nut-server upscmd -l ups@localhost 2>/dev/null | grep -q "^shutdown.return"' \
    || die "this UPS does not advertise shutdown.return"
  ok "shutdown.return supported"
}

elizabeth_down() {
  step "elizabeth clean shutdown"
  # Clean shutdown does two things: stops the array (no write hole from in-flight writes),
  # and records a clean stop so Unraid does NOT auto-start another parity check on boot.
  $SSH_E '/usr/local/sbin/powerdown' >/dev/null 2>&1 \
    && ok "powerdown issued" || warn "powerdown returned non-zero (may already be stopping)"
  # S3: without a sleep this loop was ~1s/iteration = 2min26s total, which false-times-out
  # on a healthy Unraid powerdown (array stop + unmounts routinely take 3-10+ min).
  local i
  for i in $(seq 1 90); do
    up "$ELIZ_IP" || { printf '\r%*s\r' 60 ''; ok "elizabeth down (after ~$((i*10))s)"; return 0; }
    printf '\r      waiting for array stop + poweroff... %ss elapsed (limit 900s)   ' "$((i*10))"
    sleep 10
  done
  printf '\r%*s\r' 70 ''
  abort "elizabeth did not power off within 900s - do NOT cut power to a running array"
}

cycle() {
  step "UPS output cycle"
  local st; st=$(ups_var 'ups.status')
  echo "$st" | grep -q OL || abort "UPS no longer on line power (ups.status: $st)"
  ok "UPS still on line power"

  # S5: the ONLY way to tell "the cut happened" from "nothing happened" afterwards is that
  # donkey provably reboots iff output was actually cut. Capture its boot id first.
  local boot_before
  boot_before=$($SSH_D 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
  [ -n "$boot_before" ] || abort "could not read donkey's boot_id - refusing to cut without a way to verify it worked"
  printf '%s\n' "$boot_before" > "$BOOTID_FILE"
  ok "donkey boot_id recorded ($BOOTID_FILE) - --wake will use it to prove the cut happened"

  echo "  issuing shutdown.return ..."
  # S1: capture the status. Previously this was piped straight to sed and NEVER checked, so a
  # rejected command still printed success and still tore down the VPN.
  local out rc
  out=$($SSH_D "PW=\$(docker exec nut-server awk '/^\\[admin\\]/{f=1} f&&/password/{print \$3; exit}' /etc/nut/upsd.users)
                docker exec nut-server upscmd -u admin -p \"\$PW\" ups@localhost shutdown.return" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /'
  [ $rc -eq 0 ] || abort "shutdown.return WAS REJECTED (rc=$rc). NOTHING WAS CUT.
       The VPN is still up. Fix the cause and re-run --execute (it will skip elizabeth)."
  ok "shutdown.return accepted"

  # S6/S8: the tunnel is FULL TUNNEL - once glados dies every packet blackholes.
  echo "  dropping the VPN so this Mac keeps working internet"
  scutil --nc stop "$VPN_NAME" >/dev/null 2>&1
  local vst=Connected i
  for i in $(seq 1 10); do
    sleep 1
    vst=$(scutil --nc status "$VPN_NAME" 2>/dev/null | head -1)
    [ "$vst" = "Connected" ] || break
  done
  if [ "$vst" = "Connected" ]; then
    warn "VPN STILL CONNECTED after 10s. If it has On-Demand enabled it will keep reconnecting
        into a dead peer. Disconnect it manually or turn Wi-Fi off NOW."
  else
    ok "VPN down ($vst)"
  fi

  cat <<'RECOVERY'

  -- what happens next ----------------------------------------------
  Output cuts ~OFF_DELAY after the command and returns at ON_DELAY (dead ~DEAD_SECONDS).
  Anything RUNNING at the cut returns by itself ("last state = on"):
  matryoshka -> glados/DHCP/DNS/VPN, donkey, and nodes hung in 'shutting down'.
  Anything cleanly OFF needs WOL.

  Do NOT reconnect the VPN until the DDNS record refreshes - OPNsense is its own
  Cloudflare DDNS client, so connecting early pins the stale address.

  Then:  ./scripts/ups-power-cycle.sh --wake
  -- ---------------------------------------------------------------
RECOVERY
}

wake() {
  step "WAKE - WOL anything that stayed off"
  $SSH_D 'exit 0' 2>/dev/null || die "cannot reach donkey - is it back, and is the VPN up?"

  # S5: prove the cut actually happened before assuming the hung node was reset.
  if [ -f "$BOOTID_FILE" ]; then
    local before now
    before=$(cat "$BOOTID_FILE"); now=$($SSH_D 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
    if [ "$before" = "$now" ]; then
      die "donkey did NOT reboot - THE CUT NEVER HAPPENED (boot_id unchanged).
       Do not assume the hung node was reset. Investigate before waking anything."
    fi
    ok "donkey rebooted - the cut did happen"
  else
    warn "no recorded boot_id - cannot prove the cut happened"
  fi

  # S7: upsmon runs as PRIMARY on donkey with 'AT ONBATT -> 120s -> upsmon -c fsd', and every
  # Talos node is a secondary with SHUTDOWNCMD "/sbin/poweroff --force". Waking nodes while the
  # UPS reports OB risks FSD powering the whole cluster off again minutes later.
  local st; st=$(ups_var 'ups.status')
  echo "$st" | grep -q OB && die "UPS reports OB ($st). Do NOT wake yet: upsmon would FSD after
       120s and poweroff every node. Wait for a steady OL, then re-run --wake."
  echo "$st" | grep -q OL || warn "UPS status is '$st' (not OL) - waking anyway is risky"
  ok "UPS status OK for waking ($st)"

  # S11: read from a here-string, not a pipe - a pipeline puts the loop in a subshell where
  # die() cannot abort the script.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    local name ip mac
    name=${entry%%=*}; mac=${entry##*=}; ip=$(printf '%s' "$entry" | cut -d= -f2)
    if up "$ip"; then ok "$name already up"; continue; fi
    printf '  waking %-14s (%s) ... ' "$name" "$mac"
    if $SSH_D "wakeonlan $mac" >/dev/null 2>&1; then echo "sent"; else echo "FAILED"; warn "wakeonlan failed for $name"; fi
    if [ "$name" = "elizabeth" ]; then
      printf '    waiting for the NAS'
      for _ in $(seq 1 60); do up "$ip" && break; printf '.'; sleep 5; done; echo
      # S11: ping != array started. The parity resume and NFS both need the array up.
      local mds
      mds=$($SSH_E 'mdcmd status 2>/dev/null | awk -F= "/^mdState=/{print \$2}"' 2>/dev/null)
      [ "$mds" = "STARTED" ] && ok "array STARTED (parity should resume)" \
        || warn "array state='${mds:-unknown}' - NFS is not serving yet; start it before the cluster relies on it"
    fi
  done <<< "$WAKE_LIST"
  echo; echo "  verify:  mise exec -- ./scripts/check-nodes.sh"
}

confirm() {
  printf '\n\033[1;31m%s\033[0m\n' "$1"
  printf 'Type exactly  CYCLE THE RACK  to proceed: '
  read -r a
  [ "$a" = "CYCLE THE RACK" ] || die "not confirmed - nothing done"
  ok "confirmation accepted"
}

# Exercises the same gates and confirmation as --execute, then verifies every destructive step
# COULD run, without running it. `upscmd shutdown.stop` is the key test: a no-op when nothing is
# pending, but it proves the exact credentialed upscmd path shutdown.return will use.
dry_run() {
  step "DRY RUN - verifying every action's preconditions"

  printf '  %-46s ' "elizabeth powerdown executable"
  if [ "$ELIZ_STATE" = down ]; then echo "skipped (already off)"
  else $SSH_E 'test -x /usr/local/sbin/powerdown' 2>/dev/null && echo "yes" || { echo "NO"; die "powerdown missing"; }; fi

  printf '  %-46s ' "donkey wakeonlan present"
  $SSH_D 'command -v wakeonlan >/dev/null' 2>/dev/null && echo "yes" || { echo "NO"; die "wakeonlan missing"; }

  printf '  %-46s ' "donkey boot_id readable (cut verification)"
  $SSH_D 'cat /proc/sys/kernel/random/boot_id' >/dev/null 2>&1 && echo "yes" || { echo "NO"; die "cannot read boot_id"; }

  printf '  %-46s ' "credentialed upscmd path (shutdown.stop no-op)"
  if $SSH_D "PW=\$(docker exec nut-server awk '/^\\[admin\\]/{f=1} f&&/password/{print \$3; exit}' /etc/nut/upsd.users)
             docker exec nut-server upscmd -u admin -p \"\$PW\" ups@localhost shutdown.stop" >/dev/null 2>&1
  then echo "accepted"; else echo "REJECTED"; die "upscmd with admin credentials failed - shutdown.return would also fail"; fi

  printf '  %-46s ' "VPN profile '$VPN_NAME' known to scutil"
  scutil --nc list 2>/dev/null | grep -q "$VPN_NAME" && echo "yes" || { echo "NO"; die "VPN profile not found"; }

  printf '  %-46s ' "WOL targets in config"
  echo "$(printf '%s' "$WAKE_LIST" | grep -c .) hosts"

  cat <<'PLAN'

  Would now run, in order:
    1. ssh elizabeth /usr/local/sbin/powerdown      (stops array, saves parity restart file)
    2. wait up to 900s for elizabeth to stop answering
    3. record donkey boot_id, then upscmd shutdown.return, CHECKING its exit status
    4. scutil --nc stop <vpn>, verifying it actually went down
PLAN
  printf '\n\033[1;32mDRY RUN PASSED.\033[0m Nothing cut. UPS delays were set.\n'
}

case "${1:-check}" in
  --wake)    wake ;;
  --dry-run) gates; confirm "DRY RUN - no power will be cut."; dry_run ;;
  --execute) gates
             confirm "THIS CUTS POWER TO THE ENTIRE RACK."
             [ "$ELIZ_STATE" = down ] && warn "elizabeth already off - skipping its shutdown" \
                                      || elizabeth_down
             cycle ;;
  *)         gates
             printf '\n\033[1;32mALL GATES PASSED.\033[0m Only ups.delay.start was changed.\n'
             printf 'Run with --execute when ready.\n' ;;
esac
