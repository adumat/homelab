# A `drbdsetup` hung in the kernel freezes one volume — and only a reboot clears it

The other way a node's agent stops managing a volume. Unlike the
[duplicate minor](drbd-duplicate-minor.md) it hits
**one** volume, and `drbdadm` parses cleanly. Tell them apart first, because the
duplicate-minor repair (delete the `.res`) is actively harmful here:

```sh
mise exec -- talosctl -n <ip> processes | awk 'NR==1 || $3 ~ /^D/'
# /usr/sbin/drbdsetup down <pvc>   <- state D: this trap
```

Hit 2026-10-11 on charmander with tdarr's volume: a `drbdsetup down` sat in uninterruptible
sleep from at least 04:35 UTC (the kernel's `blocked for more than` trace). The agent's
worker for that volume never returned, so when the pod moved to snorlax as a diskless
Primary, charmander never added the new peer. The evidence is split across nodes:

- the Primary shows `<node> connection:Connecting`, indefinitely
- the healthy peers show `<node> peer-disk:Inconsistent` with a growing `out-of-sync`,
  which fires `MiroirVolumeOutOfSync` on *their* agents, not the stuck node's
- the stuck node still calls itself `UpToDate` with `out-of-sync:0` — its view is stale
- `drbdadm -d adjust <pvc>` on the stuck node (dry run) prints the `new-peer` and `connect`
  it never applied: the `.res` is correct, only the kernel is behind

Snapshots of the volume time out `StagingTimedOut`, so its backups fail every night.

The broader episode is **not** fully explained: tdarr's backups had failed since 10-06 and
its pod hit `device /dev/drbd1014 not writable ... resource temporarily unavailable` on
10-10, both before the hang is proven. Treat those as a possibly separate fault if they recur.

⚠️ **Do not restart the agent.** A process in `D` cannot be killed, so kubelet's kill fails
with `DeadlineExceeded` and the pod sits in `Terminating` forever. The DaemonSet will not
start a replacement while it exists, so the node is left with **no** miroir agent at all:
mounted volumes keep working (DRBD is in the kernel), but new mounts and snapshot staging
on that node fail. `--force` on the pod deletes the object, not the process.

The fix is a reboot of that node — control planes one at a time, per the [etcd rule](../../AGENTS.md#etcd-has-three-members). A plain
`talosctl reboot --wait=false` worked, but it looks stuck: the node kept answering ping for
~6 minutes with `apid` already refusing connections, then went down and came back on its
own. Wait it out — once the API is gone no other `talosctl` mode can be issued, and
`--mode=powercycle` only bypasses kexec, so it would not have skipped that teardown anyway.
Afterwards run the [duplicate-minor checks](drbd-duplicate-minor.md) — this node has been
bitten by that on reboot before.

Data was never at risk: the healthy replicas kept replicating to each other. Confirm it
before acting by comparing the current generation UUID (first field) on each peer against
the Primary's node-id, and checking `out-of-sync:0` between them:

```sh
mise exec -- kubectl exec -n miroir-system <agent-pod> -c agent -- drbdsetup get-gi <pvc> <primary-node-id> 0
```
