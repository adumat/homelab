# Rack power cycle — resetting a node that hangs and will not answer WOL

Last exercised 2026-08-19 (`kube-ceph-03` hung with a dead NIC).

## When this is the right tool

Only when a machine on the UPS is **hung hard** — no ICMP, no Talos API, no ARP entry — and
**does not answer Wake-on-LAN**. A hung NIC cannot process a magic packet, so WOL failing is
consistent with the box still running.

Try the cheap options first:

| Situation | Do this instead |
|---|---|
| Node answers the Talos API | `talosctl -n <ip> reboot --mode=powercycle` — bypasses kexec for a real hardware reset, **no rack-wide collateral** |
| Node is cleanly powered off | WOL it: `ssh root@10.1.10.3 'wakeonlan <mac>'` |
| Someone can reach the rack | A physical press. Also preserves the console message, which is the only evidence of *why* it hung |

**Why this procedure cuts everything.** The Eaton Ellipse ECO 650 supports no `load.off`, no
`load.cycle`, and both PowerShare outlets report `switchable: no`. `shutdown.return` is its only
cycle primitive and it cuts the whole UPS: FritzBox, switch, APs, matryoshka (and so glados),
donkey, elizabeth and every node. A future UPS **must** have genuinely switchable outlet groups
so `upscmd outlet.N.load.cycle` can reset one machine instead.

⚠️ **Irreducible risk.** The UPS currently reports `ups.status: ALARM` with
`ups.alarm: "Battery voltage too low!"`. A failing battery may decline to re-energise its output.
If it does not come back, **nothing survives that can issue `load.on`** — no NUT client, no
network. That is a dark house until someone attends physically. Weigh this every time.

---

## Step 0 — preconditions

- VPN up, and SSH working to donkey (`~/.ssh/donkey`) and elizabeth (`~/.ssh/id_ed25519`).
- **A parity check may be running, but only if it will be resumed.** Check:
  ```bash
  ssh -i ~/.ssh/id_ed25519 root@10.1.10.2 'mdcmd status | grep -E "^mdResync=|^mdResyncPos="'
  grep parityTuningRestart /boot/config/plugins/parity.check.tuning/parity.check.tuning.cfg
  ```
  `mdResync=0` means idle. Otherwise progress is `mdResyncPos / mdResync` — and the rate varies
  wildly minute to minute, so estimate from an average over hours, never a 60-second sample.

  **The Parity Check Tuning plugin can carry a check across the power cycle**, but two conditions
  must both hold:

  1. **`parityTuningRestart="1"`** — set it in *Settings → Scheduler → Parity Check Tuning*. With
     `0`, a clean array stop **aborts** the check and the progress is lost (~28 h to redo from
     zero). The script's Gate 1 enforces this.
  2. **elizabeth must go down cleanly** (`powerdown`, as the script does). On an *unclean* stop the
     plugin deliberately **deletes its own restart file**:
     ```php
     sendNotification('Array operation will not be restarted', 'Unclean shutdown detected');
     parityTuningDeleteFile(PARITY_TUNING_RESTART_FILE);
     ```
     This is why `No restart information present` appeared after the 2026-08-17 crash.

  Pause/resume itself is proven on this array — 2026-08-19 it paused at 48.2 % for the mover and
  resumed at the same position 2 h 48 m later. Resume *across a power cycle* relies on the two
  conditions above.
- Ideally a **fresh UPS battery**, given the alarm above.

## Step 1 — operator shuts down all Talos nodes

Done by hand, not scripted, so you see each one.

```bash
mise exec -- talosctl -n 10.1.10.10,10.1.10.11,10.1.10.21,10.1.10.22 shutdown --force
```

**Use `--force`.** It skips cordon/drain. A drain is pointless here (everything is going down)
and it is what failed on 2026-08-19: `cordonAndDrainNode` hit
`GoAway ... ENHANCE_YOUR_CALM "too_many_pings"` against the API and the sequence misbehaved.

⚠️ **talosctl streams the whole boot/shutdown sequence and blocks.** It will look hung and can
outlast your patience. Detach it and judge by ping instead:

```bash
( nohup mise exec -- talosctl -n <ips> shutdown --force >/tmp/shut.log 2>&1 & )
for i in $(seq 1 60); do
  for ip in 10.1.10.10 10.1.10.11 10.1.10.21 10.1.10.22; do
    ping -c1 -W2 $ip >/dev/null 2>&1 && echo "up $ip"
  done; echo "---"
done
```

⚠️ **Expect some nodes to hang in `stage: shutting down`, and accept it.** Once Ceph loses
quorum, unmounting Ceph-backed volumes blocks in the kernel, so the sequence never finishes:

```
[talos] shutdown failed: failed to acquire lock: timeout
libceph: mon0 (2)10.1.10.22:3300 socket error on write
```

Re-issuing `shutdown` does **not** help — the first attempt still holds the sequence lock. Leave
them. They are not serving anything, and there is an upside: a node still **powered** at the cut
comes back by itself on AC restore ("last state = on") and does not depend on WOL at all.

*Ordering note:* the hang is worse if OSD hosts go down first, because Ceph drops below
`min_size 2` while others still need it to unmount. Shutting all four in one command, as above,
minimises the window.

## Step 2 — run the gated UPS sequence

```bash
./scripts/ups-power-cycle.sh              # gates only, changes nothing
./scripts/ups-power-cycle.sh --execute    # elizabeth shutdown, then cut UPS output
```

The gates refuse to proceed unless: VPN is up · donkey and elizabeth reachable · donkey has
`wakeonlan` · **no parity check running** · **no Talos node in `stage: running`** (`shutting down`
is accepted) · UPS on line power · NUT admin credentials work.

Setting `ups.delay.start` doubles as the credential test, so a wrong password fails **before**
elizabeth is shut down rather than after, when there would be no way to issue the command.

`--execute` then stops elizabeth's array cleanly — which prevents a write hole **and** stops
Unraid auto-starting another multi-hour parity check on the way back — issues
`shutdown.return`, and **drops the VPN**. That last part is not optional: the WireGuard profile is
**full tunnel**, so once glados dies every packet from the Mac blackholes and you cannot even
watch for recovery.

## Step 3 — recovery

`~20s` after the command the output cuts; it returns after `OFF_SECONDS` (default 60).

Anything **running** at the cut returns on its own: matryoshka → glados, DHCP, DNS, VPN; donkey;
plus any node left hung in `shutting down`. Anything **cleanly off** needs WOL.

⚠️ **Do not reconnect the VPN until the DDNS record refreshes.** OPNsense is its own Cloudflare
DDNS client, so while it is down `vpn.${DOMAIN}` is frozen at the pre-outage address — and on a
dynamic line that address may already belong to another ISP customer. It will answer pings and
look healthy. Reconnecting early pins the stale address.

```bash
./scripts/ups-power-cycle.sh --wake       # WOLs whatever stayed off, NAS first
mise exec -- ./scripts/check-nodes.sh
```

The wake order matters: **elizabeth first**, then a pause, then the cluster — nine apps mount NFS
inline, and booting Talos before the NAS serves is the documented stale-handle failure.

## MAC reference (for manual WOL from donkey)

| Host | IP | MAC |
|---|---|---|
| elizabeth | 10.1.10.2 | `14:da:e9:4d:e7:65` |
| kube-nuc | 10.1.10.10 | `1c:69:7a:a5:93:fc` |
| kube-hp | 10.1.10.11 | `f8:b4:6a:a5:87:ed` |
| kube-ceph-01 | 10.1.10.21 | `e8:6a:64:a4:89:ca` |
| kube-ceph-02 | 10.1.10.22 | `e8:6a:64:f6:ff:af` |
| kube-ceph-03 | 10.1.10.23 | `e8:6a:64:76:2a:18` |

```bash
ssh -i ~/.ssh/donkey root@10.1.10.3 'wakeonlan <mac>'
```

WOL arming was verified 2026-08-19: all four Talos nodes report `wakeOnLAN: ["magic"]` via
`talosctl get ethernetstatus eno1`, elizabeth reports `Wake-on: g`. **matryoshka cannot be woken**
— its WAN NIC is a USB Realtek, and USB NICs cannot do WOL.

## Traps, all observed rather than theorised

| Trap | Consequence |
|---|---|
| `talosctl` streams and blocks | Looks hung; detach it and judge by ping |
| Re-issuing `shutdown` on a stuck node | `failed to acquire lock: timeout` — the first attempt still holds it |
| Cutting power with a node still `running` | Hard-kills a live node. Gate 2 exists for this |
| Cutting power to a running Unraid array | Write hole; 2026-08-17 produced 145 corrected parity blocks |
| Leaving the VPN up through the cut | Full tunnel to a dead peer blackholes all Mac traffic |
| Trusting `vpn.${DOMAIN}` after an outage | Stale record, possibly another customer's IP, answers pings |
| Rebooting nodes without silencing `NodeUnexpectedReboot` | Pages you once per node; teaches you to ignore a critical alert |
| Assuming a big `sbSyncErrs` means a dying disk | Check character not count: `mdResyncCorr=1` + one contiguous burst + clean SMART = a write hole, not hardware |
