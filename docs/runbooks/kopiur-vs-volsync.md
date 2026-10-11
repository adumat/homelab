# Backups: kopiur and VolSync both exist, and they are not interchangeable

Two backup components live side by side while kopiur is being validated:
`components/persistence` (VolSync, 18 apps) and `components/kopiur` (1 app, prowlarr).

Moving an app between them is **not** a one-line change, for two reasons:

1. **The PVC's `dataSourceRef` is immutable.** Both components set one — VolSync to a
   `ReplicationDestination`, kopiur to a `Restore` — so the switch fails with
   `spec is immutable after creation`. The PVC must be deleted and recreated, which means
   copying the data out first.
2. **The old `ReplicationDestination` is not pruned.** It carries
   `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`, so Flux leaves it behind when the
   component is removed. It is inert, but it must be deleted by hand.

Rename `VOLSYNC_CAPACITY` → `KOPIUR_CAPACITY` and drop `CACHE_CAPACITY` when migrating.
`CRON_EXPRESSION` keeps its name deliberately, so the schedule stagger carries over.

**The data does not need copying.** A second `ClusterRepository`, `nas-volsync`, is attached
read-only to VolSync's repository, so the populator can refill a recreated PVC from that
app's own last VolSync backup. Verified on prowlarr: 739 files restored in 35 s, matching
`kopia ls -lr` for the snapshot exactly.

Two things make it work, and both differ from the main repository:

- `usernameExpr: policyName` — VolSync wrote `prowlarr@downloads`, the main kopiur
  repository writes `downloads-prowlarr`
- `Restore.spec.source.identity` with `sourcePath: /data` — the field is documented for
  "foreign writers", which is what VolSync is. VolSync mounted at `/data`; kopiur uses
  `/pvc/<name>`

`nas-volsync` is `mode: ReadOnly` with maintenance and create both disabled, because that
repository holds the only backups for every app still on VolSync. Do not relax any of the
three.

kopiur discovers that repository on its own, so every VolSync snapshot also exists as a
`Snapshot` object in the app's namespace, with the identity to restore it in
`.status.snapshot.identity`. Read it from there rather than reconstructing it.

⚠️ **Two identities exist per app, and one of them is a trap.** Alongside `<app>@<ns>` there
is a `<app>-src@<ns>` from VolSync's older naming, frozen at 2026-01-20. Restoring it does
not fail — it returns seven-month-old data. Check the snapshot's end time before restoring.

Two more, both learned the hard way while archiving node-red between the two repositories:

- **A `Restore` in a namespace that has no repository secret needs
  `credentialProjection.enabled: true`.** The mover Job loads credentials with `envFrom`,
  which cannot cross namespaces, so it sits in `Pending` on `MissingCredentialsSecret`. The
  `ClusterRepository` must also allow it (`credentialProjection.allowed: true`)
- **Two filesystem repositories must not share `backend.filesystem.path`.** A replication
  mover mounts source and destination in one pod, and the webhook refuses the shared
  mountPath. `nas` keeps `/repo`, `nas-volsync` uses `/repo-volsync`. That field is only the
  in-pod mount point — changing it moves no data

To copy snapshots between repositories, use a `SnapshotReplication`. Its `sourceRef` is
opened read-only and never written to, so it is safe against the live VolSync repository.
With `spec.pruning` absent the copies **survive deletion of the CR**, which makes it the
right shape for a one-shot archival copy: apply it, let one run finish, delete it. Do not
commit one — `schedule.cron` is required, so in git it would re-run forever.

**`stats.fileCount` from `kopia snapshot list` is not a file count.** It counts what that
incremental run uploaded — 594, 543, 544 across three daily snapshots of a near-static
volume. For a tree total use `kopia ls -lr <snapshotID>`.
