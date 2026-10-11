# A power cut can corrupt the kopia repository mid-write

Seen 2026-08-17, on a **filesystem** repository over NFS. The live repository is now
`ClusterRepository/garage` (S3), where blobs are objects rather than files: the error should
look the same, but this diagnosis and repair have not been exercised there.

An unclean shutdown while a backup was uploading left **zero-length blobs**
on the NAS: the directory entries exist, the content was never flushed. Every mover then dies
on the same line, and it reads like an encryption or password fault rather than truncation:

```
error loading index blob xn129_...: decrypt blob: ciphertext too short: 0
```

kopiur reports the repository `Ready=False` / `BackendUnreachable` and opens its circuit
breaker, so **every** app sharing that repository stops backing up — 15 of them here, for 36
hours, silently.

Diagnose on the NAS, not in the cluster:

```sh
ssh root@elizabeth.lan "find /mnt/user/backups/<repo> -type f -size 0"
```

Check the mtimes. If they all share one minute, the damage is one interrupted write and
nothing else is suspect. Here all 12 were stamped 01:30 — unifi-mongo's slot, the backup in
flight when the power died.

Repair, in this order:

1. **Copy the repository first**, detached so a dropped session cannot kill it:
   `setsid nohup cp -a /mnt/user/backups/<repo> /mnt/user/backups/<repo>-preblackout-<date> &`.
   Confirm byte and file counts match before touching anything.
2. Delete **only** zero-length files, and only under the live repository:
   `find <repo> -type f -size 0 -print -delete`. A zero-length blob contains nothing, so
   deleting it cannot lose data that is not already lost — worst case the error changes from
   `ciphertext too short` to a missing blob, for content that was gone either way.
3. `kubectl rollout restart deploy/kopiur-controller -n volsync-system` to reset the circuit
   breaker; it will not retry promptly on its own.
4. Verify a real write, not just the condition: create one kopiur `Snapshot` by hand
   (`generateName: <app>-manual-`, `spec.policyRef.name: <app>`) and wait for phase
   `Succeeded`.

Index blobs (`xn…`) are rebuilt by kopia. Content blobs (`p…`, `q…`) are lost, but if they
belong to an interrupted backup no completed snapshot references them. Log blobs (`_log…`)
are irrelevant.

**The wider pattern:** an unclean shutdown also makes Unraid start a correcting parity check,
which saturates the array for 20–28 hours. That is the documented trigger for NFS stale
handles and for backup slots colliding — so after any power event, expect the repository
problem *and* stale mounts *and* slow backups, all from the same root cause.
