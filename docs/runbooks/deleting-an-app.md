# Deleting an app: the backups survive, the PVC does not go away

Two facts that sound like each other's opposite. Both proven by removing karakeep, 2026-08-20.

**Backups survive, by design.** Removing an app from git prunes its `SnapshotPolicy` and
`SnapshotSchedule`, and Kubernetes garbage-collects the `Snapshot` CRs they owned — but the kopia
snapshots in the repository stay. Two *schema* defaults guarantee it:

| Field | Default | Fires when |
| --- | --- | --- |
| `SnapshotSchedule.spec.deletion.onScheduleDelete` | `Retain` | the schedule is deleted or replaced |
| `SnapshotPolicy.spec.deletion.onPolicyDelete` | `Retain` | the owning policy is gone |

A produced `Snapshot`'s own `deletionPolicy` does default to `Delete`, but it is only consulted
if someone explicitly sets `onScheduleDelete: Delete` to opt into the cascade. Nothing you do in
git destroys repository data by accident — upstream made `onScheduleDelete` deliberately
two-valued so the ambiguous state is unrepresentable.

The snapshots come back as `origin: discovered` with `deletionPolicy: Retain` (forced). Three
non-obvious things about finding them again:

- they are named `<repo>-disc-<hash>`, **not** `<app>-*` — grepping for the app name finds nothing
- `origin` is a **label**, not a spec field: `-l kopiur.home-operations.com/origin=discovered`
- the catalog does not refresh on a tight interval, so they may not appear at all until you ask:

```sh
kubectl annotate clusterrepository garage \
  kopiur.home-operations.com/catalog-scan-requested-at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
# then watch .status.catalog.lastRefreshAt and .discoveredBackupCount
```

Confirm identity from `status.snapshot.identity` (`sourcePath: /pvc/<app>`,
`username: <ns>-<app>`) and cross-check `status.stats.sizeBytes` against what the schedule
recorded — the CR name tells you nothing.

⚠️ Retention stops applying once no policy owns them, so a decommissioned app's snapshots persist
indefinitely instead of ageing out. That is what you want for an archive, but it accumulates.

**The PVC is left behind.** karakeep's Kustomization was pruned and its HelmRelease,
ExternalSecret, three Deployments, SnapshotPolicy and SnapshotSchedule all went with it — while
the 5 Gi PVC stayed `Bound`, with an empty `deletionTimestamp`, still carrying its
`kustomize.toolkit.fluxcd.io/name` label. Removing an app is not finished until you check:

```sh
kubectl get pvc,pv -A | grep <app>
```

Delete it by hand *after* confirming the backups are retained. The PV's reclaim policy is
`Delete`, so the RBD image goes with it.
