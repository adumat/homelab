# One duplicate DRBD minor breaks every volume on that node

`drbdadm` parses **all** of `/etc/drbd.d/*.res` on every invocation, so two resources
declaring the same `device-minor` for the same peer make it exit 10. The agent runs
`drbdadm adjust` per volume, so **every** volume on that node fails at once — not just the
conflicting pair.

Hit 2026-09-22 on charmander, triggered by its Talos v1.13.10 reboot: 15 of 48
MiroirVolumes `Degraded`, three pods unable to mount for 23h, and 12 of 27 kopiur snapshots
failing `StagingTimedOut` because staging clones could not get a leg on that node.

**Nothing in the symptom names the cause.** Pod events say `diskless leg not realized on
node <n>`, `No such resource`, or `DRBD state unreadable on node <n>`; the MiroirVolume
says `Degraded 2/3` while every real replica is `UpToDate`; kopiur blames its own staging
timeout. The truth only appears from inside the agent:

```sh
mise exec -- kubectl exec -n miroir-system <agent-pod> -c agent -- drbdadm status
# exit status 10: conflicting use of device-minor 'device-minor:<node>:<minor>'
mise exec -- kubectl exec -n miroir-system <agent-pod> -c agent -- \
  sh -c 'awk "{print \$2}" /etc/drbd.d/minor.assign | sort | uniq -d'
```

**A wrong peer minor is normal — do not "fix" it.** The generator writes one uniform minor
into every `on "<node>"` stanza rather than each node's real minor, so nearly every `.res`
misstates its peers. DRBD connects by node-id and address, so this is inert at runtime; 42
volumes ran fine that way. Only a *duplicate* breaks the parse.

Repair by correcting the ledger first, then deleting that volume's `.res` to regenerate it:

```sh
sed -i 's|^<pvc> <old>$|<pvc> <free>|' /etc/drbd.d/minor.assign
rm /etc/drbd.d/<pvc>.res
```

⚠️ **Reassign the claimant that has no live device.** Check `/dev/drbd<minor>` first: one of
the two is usually serving a running pod, and reassigning that one pulls a device out from
under it.

⚠️ **Never delete a `.res` before fixing the ledger.** The allocator can hand out a minor
that is already assigned, so deleting a file to force regeneration is how a duplicate gets
*written into* the ledger — converting a stale-file conflict into a recorded one and taking
more volumes down than it repairs.

Clearing the stale `status.perNode.<node>` entry does not help either: the agent rewrites
the key with a null minor and regenerates the file regardless. The ledger is the only
source that decides the outcome.
