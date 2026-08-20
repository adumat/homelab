# Homelab Roadmap

## Roadmap

Phases in order. Each gets an execution plan under `docs/superpowers/plans/` **when you
reach it**, not before: that way every plan is written against the real state of the repo
rather than the state predicted weeks earlier.

The half-numbered phases were inserted as work revealed them — 1.5 by a recurring failure,
2.5 because a 19-app migration should not be planned before a single volume has been
restored, 2.6 by a node that hung unreachable and had to be power-cycled by hand, and 2.7 by
the one backup kopiur cannot cover silently failing for two days on the least reliable host.

### Phase 1 — AGENTS.md and CI in cluster: konflate, runner, image-pull — ✅ done 2026-08-08

- [x] Write `AGENTS.md` at the repo root
- [x] Traps section, every claim verified against the repo
- [x] Remove `flux-local` from `.github/workflows/` and `.mise.toml` (archived upstream)
- [x] Add `flate` as a CLI — gate passed, 224 resources render
- [x] Deploy `konflate` on `envoy-external`, webhook delivering 202, status checks posting
- [x] Deploy `actions-runner-controller` with a dedicated GitHub App
- [x] Add the `image-pull` workflow — verified end to end with the network fence active

**What differed from the design.** `os:reader` cannot `talosctl image pull`, so the runner
uses `os:operator`; and Talos gates API access from pods behind two allow-lists in
`talos-api-access.yaml`, which had to be extended for the new namespace and role.

**Two silent failures found and fixed**, both now written up in [AGENTS.md](AGENTS.md):
an ARC race binding the listener to an `EphemeralRunnerSet` it then deleted, and a
`CiliumNetworkPolicy` whose selector matched no pods while reporting healthy.

### Phase 1.5 — NFS stale handles — ⏸ deferred, waiting for the next occurrence

**Deliberately parked.** The failure is intermittent and triggered by elizabeth's mover or
parity check, so it cannot be investigated on demand — and provoking it means breaking
pods on a live cluster on purpose. Picked up the next time it happens.

**Capture this before touching anything**, or the incident yields annoyance instead of
evidence:

```bash
mise exec -- kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
mise exec -- talosctl -n <node-running-the-stuck-pod> dmesg | grep -i 'nfs\|stale'
mise exec -- talosctl -n <node> mounts | grep nfs
mise exec -- kubectl describe pod <pod> -n <ns> | grep -iA3 'mount\|stale'
```

Plus the value of `nfs_canary_health_overall` at that moment, and whether elizabeth's
mover or parity check was running.

The recognition and manual recovery procedure is in [AGENTS.md](AGENTS.md), traps section.

The most annoying recurring failure in the cluster. Unraid drops NFS connections when the
mover or the parity check runs; the file handle goes invalid and **does not heal on its
own**, leaving pods stuck in `Terminating` or applications that cannot see their files.
Today there is only mitigation: `nfs-scaler` scales apps to zero when the canary reports
the failure, and the fix is recreating the pod by hand.

Nine apps mount NFS inline with `type: nfs` and are the exposed ones: frigate,
home-assistant, kopia, qbittorrent, radarr, sonarr, filebrowser, jellyfin, romm.

- [ ] Understand **why** the mount never recovers: `soft` should make I/O fail and allow a
      remount, yet the handle stays poisoned. Check whether `nconnect=8` is involved — it
      opens several TCP connections whose state could diverge
- [ ] Evaluate moving from inline `type: nfs` volumes to **PVs with explicit
      `mountOptions`**: they already survive the "Unraid stops serving NFSv4.0" case, so
      they may behave better here too
- [ ] Evaluate an automatic remount, or a DaemonSet that detects `ESTALE` and forces the
      remount on the node, instead of waiting for manual intervention
- [ ] Make recovery automatic: if the pod cannot heal, at least have it recreated instead
      of sitting in `Terminating`
- [ ] Reduce the upstream cause: check whether elizabeth's mover can be configured not to
      interrupt active NFS sessions
- [ ] Improve `nfs-canary` (see Follow-ups): today it detects, but does not distinguish the
      mover from the parity check, nor report which share died

Until this is solved, the recognition and recovery procedure lives in
[AGENTS.md](AGENTS.md), traps section.

### Phase 2 — storage validation: prove kopiur and miroir, migrate nothing

Design: [2026-08-08-phase2-storage-validation-design.md](docs/superpowers/specs/2026-08-08-phase2-storage-validation-design.md)

Two candidates, one small workload each, nothing existing touched. Needs no rollback plan
precisely because nothing changes. Ending with "we are staying on VolSync and Ceph, here is
why" is a successful outcome.

Measured state (the earlier numbers here were wrong — they counted YAML occurrences, not
objects): **32** PVCs on `ceph-block`, **13** on `openebs-hostpath`, **19** VolSync sources
all on `ceph-block`.

- [x] **kopiur 0.10.1 plus a `ClusterRepository` on a fresh NFS path** — 2026-08-12.
      `elizabeth.lan:/mnt/user/backups/kopiur`, `nas`, `Ready`. VolSync kept running against
      its own 17 GiB repository throughout. Bootstrap needed `chown 99:100` and `chmod 777`
      on the export, not `1000:1000`: the Unraid share is `all_squash` with
      `anonuid=99,anongid=100`, so every write arrives as 99:100
- [x] **`components/kopiur`** — 2026-08-12. Mirrors `components/persistence`, so an app
      switches by changing one line. Rename `VOLSYNC_CAPACITY` → `KOPIUR_CAPACITY`, drop
      `CACHE_CAPACITY`, keep `CRON_EXPRESSION` so the schedule stagger carries over
- [x] **prowlarr migrated and backing itself up unattended** — 2026-08-12. The PVC had to be
      recreated rather than patched: its `dataSourceRef` pointed at
      `ReplicationDestination/prowlarr-dst` and that field is immutable.
      **Confirmed 2026-08-13: a snapshot ran on its own** at 00:18:59 with
      `origin=scheduled` on the `15 0 * * *` cron — so the migration works in steady state,
      not only when triggered by hand
- [x] **Prove the restore, not the backup:** restore a snapshot into a fresh PVC through the
      `Restore` populator and diff it against the source. A backup never restored is a hope.
      **Done 2026-08-12: `diff -r` exit 0, 741 files, hash identical to the pre-migration
      volume.** Snapshot 111 s, restore+bind 34 s, repository 3.3 MB
- [x] **How phase 2.5 moves data — settled 2026-08-12: kopiur restores directly from
      VolSync's repository. No data copying needed.**

      A second `ClusterRepository` (`nas-volsync`) attached to
      `/mnt/user/backups/volsync` and restored prowlarr's 2026-08-12T00:15 VolSync backup
      into a fresh PVC via the populator, in **35 s**. Result: **739 files**, matching
      exactly what `kopia ls -lr` reports for that snapshot, 57,466,575 bytes against the
      snapshot's 57,396,943, `config.xml` intact.

      What made it work:

      | | VolSync writes | main kopiur repo | `nas-volsync` uses |
      |---|---|---|---|
      | hostname | `downloads` | `downloads` | `hostnameExpr: namespace` |
      | username | `prowlarr` | `downloads-prowlarr` | `usernameExpr: policyName` |
      | path | `/data` | `/pvc/prowlarr` | `source.identity.sourcePath: /data` |

      `Restore.spec.source.identity` is the mechanism — documented for "foreign writers",
      which is exactly what VolSync is. No `adoption`, no `sourcePathOverride`, no writes.

      **VolSync's repository was never touched:** 17,534,923,192 bytes and 805 entries
      before and after, verified twice. `mode: ReadOnly` plus `maintenance.enabled: false`
      plus `create.enabled: false` held.

      Consequence for 2.5: per app it is swap the component, rename the substitutions,
      delete and recreate the PVC — the populator refills it from that app's own last
      VolSync backup. `pv-migrate` is not needed.

      ⚠️ **Do not use `stats.fileCount` from `kopia snapshot list` as an expected file
      count.** It is an incremental upload count — 594, 543, 544 across three daily
      snapshots of a near-static volume. `kopia ls -lr <id>` gives the tree total.
- [x] **Phase 2.5's work list, enumerated rather than estimated.** Leaving `nas-volsync`
      deployed had an unplanned benefit: kopiur discovered the whole repository on its own,
      **441 `Snapshot` objects**, each landing in the right namespace with its exact identity
      readable off `.status.snapshot.identity`. So 2.5 never has to guess an identity — read
      it from the object. All 441 are `deletionPolicy: Retain`, owned by the
      `ClusterRepository`.

      36 identities, of which only **18 are live** — one `ReplicationSource` each, all
      backed up on 2026-08-12. Those 18 are exactly the phase 2.5 work list:

      | namespace | apps |
      |---|---|
      | `downloads` | metube, pyload-ng, qbittorrent, radarr, sonarr |
      | `home` | esp-home, frigate, home-assistant |
      | `media` | jellyfin, jellyseerr, romm |
      | `network` | unifi, unifi-mongo |
      | `services` | filebrowser, karakeep, ocis, paperless, vaultwarden |

      The other 18 are dead weight, and two kinds of it:

      - 16 identities named **`<app>-src@<ns>`**, frozen at 2026-01-20 — VolSync's older
        naming. ⚠️ **Every one of them shadows a live app.** Restoring
        `prowlarr-src@downloads` instead of `prowlarr@downloads` succeeds and hands back
        7-month-old data. Match on the identity, never on the app name
      - **node-red@home**, 19 snapshots ending 2026-07-30 — a decommissioned app. No PVC, no
        directory in the repo, and nothing prunes it because no `SnapshotPolicy` owns
        `nas-volsync`. **Archived into the kopiur repository 2026-08-12** (below), so
        retiring VolSync's repository no longer destroys it

      The 16 `-src` sets need no deletion work: they exist only in VolSync's repository,
      which 2.5 retires wholesale, so they die with it. Deleting them sooner would mean
      granting write access to the one repository still holding all 18 apps' backups.
- [x] **node-red archived out of VolSync's repository — 2026-08-12.** It was the only
      identity that retiring that repository would have destroyed, since the app itself is
      gone from git.

      A one-shot `SnapshotReplication` (`kopia snapshot migrate` underneath) copied
      **all 19 snapshots**, January through July, 582 KB. `sourceRef` is documented as
      "opened read-only … a replication never writes to its source", which is what makes it
      safe against the live repository — confirmed, `du -sb` still 17,534,923,192 bytes.

      Verified the way task 3 taught: restored the newest snapshot from **both**
      repositories into separate PVCs and diffed them. `diff -r` exit 0, 9 files,
      75,714 bytes either side. A copy that lands is not a backup; a copy that restores is.

      Applied imperatively and then deleted, deliberately. `pruning` absent means copies
      "survive deletion of this CR" — verified, 19 still present afterwards — so committing
      it would have re-run the copy every five minutes forever.

      Two traps it surfaced, both now in [AGENTS.md](AGENTS.md): two filesystem repositories
      cannot share `backend.path`, and a restore into a namespace without the repository
      secret needs `credentialProjection.enabled`.
- [x] **DRBD system extension — done 2026-08-12, all five nodes.** Landed together with the
      Talos **v1.13.5 → v1.13.8** bump via PR #427, one rolling reboot for both. Every node
      reports `drbd 9.3.3-v1.13.8` on schematic `e4e5b0e3`, etcd both members `OK`, Ceph
      `HEALTH_OK`.

      The `factory-url` + `schematic` annotations were what made it work — tuppr's log
      confirms `Built target image from FactoryURL override` per node. **Order matters on the
      way out:** `apply-node` all five first, so `.machine.install.image` carries the new
      schematic, and only then remove the annotations. Removing them first leaves the runtime
      schematic absent from the install-image path, which is exactly the case tuppr's safety
      net refuses — the next upgrade would park. Both done, annotations now gone.

      ⚠️ **The rollout stalled once, and the failure mode is worth knowing.** After each
      reboot a node can come back with a **spurious `DiskPressure`** condition and its
      `NoSchedule` taint. Rook pins mons and OSDs to a node with `nodeSelector`, so one
      tainted node means that mon and OSD cannot schedule at all, Ceph never reaches
      `HEALTH_OK` — and `HEALTH_OK` is the gate tuppr waits on. Left alone the run parks at
      4/5 rather than breaking anything, but it does not self-heal.

      Distinguish the two cases by asking kubelet, not `/var`, since
      `talosctl usage` and `statfs` disagree by ~12 GB:
      `kubectl get --raw /api/v1/nodes/<n>/proxy/stats/summary`. Thresholds are stock,
      `nodefs.available` 10% and `imagefs.available` 15%.

      - **Spurious** (3 of 5 nodes: ceph-01 63% imagefs free, ceph-03, nuc 29% free) — a
        stale eviction-manager observation latched at boot. `talosctl -n <ip> service kubelet
        restart` clears it instantly and leaves running containers alone
      - **Real** (ceph-02, 9% imagefs free) — and it does not self-heal. kubelet's log shows
        the deadlock: GC runs, then `must evict pod(s)` → every remaining pod is critical →
        `unable to evict any pods`

      **The cause was 54 leftover terminal pods, not images.** The drains left that many pods
      in `Error`/`Evicted`/`ContainerStatusUnknown`, and they pinned containerd space that
      image GC cannot touch: on ceph-02 containerd held **35.5 GB** (23.7 GB overlayfs
      snapshots + 11.8 GB content blobs) against only **5.5 GB of live images**.
      `kubectl delete pods -A --field-selector status.phase=Failed` took it from 4 GB free /
      9% imagefs to **40 GB / 75%**, the taint cleared itself, and mon-a plus OSD-1 scheduled
      immediately — Ceph back to `HEALTH_OK`, 3/3 mons, 3/3 OSDs.

      Cost of not spotting it sooner: mon-a and OSD-1 were **evicted** off ceph-02 and could
      not return, so Ceph sat at 2/3 mons with `CephMonDownQuorumAtRisk` firing, and
      `cluster18-1` could not schedule. Prometheus made this obvious where the rollout status
      did not — 36 alerts down to 7 once fixed, and the 5 remaining
      `KubeDaemonSetRolloutStuck` were lagging against DaemonSets already at `ready=5`.

      This was the third time the 50 GiB `/var` cap bit (kube-nuc in phase 1, the v1.13.5
      upgrade before it) and the second time terminal pods were the mechanism — **fixed at the
      source the same day**, see below.
- [x] **`/var` pressure fixed at the source — 2026-08-12. Pod GC, not a bigger disk.**

      All three incidents shared one mechanism, and it is not image bloat: a ReplicaSet never
      deletes its own `Failed`/`Succeeded` pods, and each dead Pod forces kubelet to keep its
      containers, which pin an overlayfs snapshot **and** the image they ran from — space
      image GC cannot reclaim however it is tuned. `/var` was never genuinely full; it was
      full of uncollected garbage.

      `terminated-pod-gc-threshold: "30"` now set on both control planes (default **12500**
      never fires on five nodes). The number has to sit *below* the garbage level, because
      PodGC deletes oldest-first only once the count **exceeds** it — 30 reaps a 75-pod pile
      to 30, whereas the 50 first considered would have deleted four. CronJob history (3
      CronJobs) and recent failures survive.

      Plus `NodeVarSpaceLow` at 20% free, 5 points ahead of kubelet's 15% eviction line. The
      built-in `KubeNodePressure` only fires once `DiskPressure` is already set — by which
      time mons are being evicted.

      **Deliberately not done: raising the cap.** The disk is fully allocated — on ceph-02's
      256 GB: 2.2 GB boot, 0.1 GB state, 53.6 GB `/var`, **200 GB `local-hostpath`**. Growing
      `/var` means shrinking local-hostpath, which means wiping it per node — and that is not
      a cheap cache reset: it holds the **three Ceph mon stores** and **both Postgres
      clusters** (cluster18 + immich-db, data and WAL) alongside jellyfin-transcode and
      immich-ml-cache. Recoverable one node at a time, but hours of care, not minutes. Since
      phase 2's goal is removing Ceph, which deletes those mon PVCs
      and changes what local-hostpath must hold, repartitioning now is work to redo.

      ⚠️ **Revisit with the Ceph decision.** The allocation is backwards — 200 GB holding
      under 1 GB while the 53.6 GB `/var` is the binding constraint — and it is still tight
      when perfectly clean: kube-hp sits at **24% free**, above its own 75% image-GC trigger,
      with kube-nuc at 27% and ceph-03 at 28%.
- [x] **miroir installed on a loopfile — 2026-08-13.** Chart 0.11.22, pool on
      `/var/mnt/local-hostpath/miroir` on the three workers. Nothing taken from Ceph, no
      repartitioning, no spare disk. `REFLINK_OK` verified on all three first, since the
      backend refuses a non-reflink `baseDir`.

      Three things the chart or the plan could not tell us, each of which would have failed
      silently or confusingly:

      - **The DRBD module was never loaded.** Phase 2's Task 4 installed the *extension*,
        which only ships the module. `/proc/drbd` was absent and every agent logged
        `DRBD kernel module unavailable; running local-only` — `miroir-local` would have kept
        working while `miroir-replicated` quietly could not. Fixed with `machine.kernel.modules`
        and the mandatory `usermode_helper=disabled` (the kernel otherwise calls
        `/sbin/drbdadm`, absent on Talos). **No new schematic, no reboot** — Talos loaded it on
        `apply-config`
      - **Port 7000 collides with Ceph.** Agents run hostNetwork, Rook here is
        `provider: host`, and the mgr dashboard holds 7000. Ceph's msgr range is
        `ms_bind_port_min` 6800 to `ms_bind_port_max` **7568**, so `drbd.portBase` is 7700 —
        above the whole range. The live volume confirmed port 7700
      - **`agent.loopfileBaseDirs` must repeat every `loopfile.baseDir`.** The topology lives
        in CRs the chart cannot read at render time while the hostPath mounts are pod spec.
        Also: StorageClass parameter keys are namespaced (`miroir.home-operations.com/replicas`),
        not bare
- [x] **Every functional test passed — 2026-08-13.**

      | test | result |
      |---|---|
      | `miroir-local` provision + write | Bound, `1/1` |
      | `miroir-replicated` provision + write | Bound, **`2/2`** diskful + a **diskless tie-breaker** on the third node, so quorum has 3 voters |
      | snapshot | `readyToUse` in ~12 s |
      | restore into a fresh PVC | checksum **exact match** |
      | read from the *other* diskful leg | exact match, so replication is real and not just claimed |
      | **reboot the primary-leg node** | **exact match, 209,715,200 bytes**; volume `Degraded` → `Ready` in ~45 s |
      | teardown | all `MiroirVolume`s reclaimed, all three `baseDir`s empty — no leaked loopfiles |

      ⚠️ **The first durability run was invalid and the trap is easy to repeat.** The writer
      was a bare Pod, so `restartPolicy` defaulted to `Always`; the node reboot restarted the
      container, which re-ran `dd` and rewrote **both** the data and the recorded checksum.
      That does not merely lose the baseline — it makes an intact volume and a wiped one look
      identical, because a wiped volume gets refilled the same way. Redone with
      `restartPolicy: Never`, an idempotent write, the writer deleted before the reboot, and
      the expected checksum held outside the cluster.
- [x] **Memory: miroir costs ~3% of Ceph.**

      | | pods | memory |
      |---|---|---|
      | Ceph | 34 | **6.81–6.99 GiB** |
      | miroir idle | 6 | **173 Mi** |
      | miroir under load | 6 | **204 Mi** (agents 18–27 Mi, controller 65 Mi) |
      | OpenEBS, for scale | 1 | 15 Mi |

      Ceph measured **higher** than the 5.2 GiB recorded on 2026-08-08, on 13 GiB nodes that
      have already failed to schedule immich. That is ~34× more memory for 45 GiB of data.

      **Verdict: miroir is a credible Ceph replacement, and nothing found here argues against
      it.** It provisions, snapshots, restores, replicates across nodes, survives losing the
      node holding the primary leg, and tears down cleanly, at a thirty-fourth of the memory.

      **What this evaluation still cannot tell you, and the decision is yours:**

      - **Performance is unproven.** A loopfile on shared XFS says nothing about the NVMe that
        Ceph currently owns. This is the one test that requires committing disks
      - **Durability drops from three replicas to two**, and the third leg is diskless — a
        tie-breaker for quorum, not a copy of the data
      - **Maturity, not capability, is the risk.** miroir is pre-1.0 and would become primary
        storage
      - **Capacity is uneven and shared.** `kube-ceph-01` has only **64 GB** of
        local-hostpath against 200 GB on the other two, so it binds replica placement — and
        that filesystem also carries the openebs-hostpath PVCs (the Ceph mon stores and both
        Postgres clusters), so miroir and they compete. This is the same partition split
        queued for revisit; a real miroir rollout wants dedicated disks rather than a loopfile

**OpenEBS stays.** The roadmap's reason for replacing it was snapshots, and nothing on
local storage needs them: none of the 13 PVCs has a ReplicationSource, and none should —
CNPG backs itself up, Ceph mons keep their own quorum, and the rest are caches.

**Why miroir matters here.** The goal is removing Ceph, which looks oversized: **45 GiB
stored** on 2.7 TiB with 3× replication, costing **~5.2 GiB of RAM** on 13 GiB nodes that
have already failed to schedule immich. CephFS holds 451 KiB and zero PVCs; there is no
object store; RWX comes from NFS. The capability that normally blocks leaving Ceph does not
apply.

**Measured 2026-08-13:** Ceph is **6.81–6.99 GiB across 34 pods**, higher than the 5.2 GiB
above. miroir does the same job for **204 Mi across 6**. The caveats that remain are in the
verdict item.

**Risk:** backups run over NFS to elizabeth, the host whose stale handles are parked as
phase 1.5. Dual-running roughly doubles backup I/O to it, which is why the existing
00:00–01:30 UTC schedule stagger must be preserved.

### Phase 2.5 — the actual migration

Planned **after** phase 2, using its real numbers rather than guesses. Phase 2 settles how
data moves, so this phase starts with that already decided.

**Known before starting**, from the prowlarr pilot:

- Switching an app is **not** a one-line change: both components set the PVC's immutable
  `dataSourceRef`, so the PVC must be deleted and recreated
- Each app leaves an orphaned `ReplicationDestination` that Flux will not prune
- Rename `VOLSYNC_CAPACITY` → `KOPIUR_CAPACITY`, drop `CACHE_CAPACITY`, keep `CRON_EXPRESSION`
- Per-app cost on a 1 GiB volume: snapshot 111 s, restore+bind 34 s

**The exit condition is every PVC, not every VolSync app.** Phase 3 rebuilds the cluster from
these backups, so an unprotected PVC is data that will not come back. Measured today: **33 on
`ceph-block` + 13 on `openebs-hostpath`, of which only 19 are protected — 14 have no backup at
all.** Stating it as "migrate all PVCs" is not checkable and quietly invites someone to point
kopiur at a Postgres data directory, so:

> **Exit condition: every PVC either has a kopiur `SnapshotPolicy`, or is explicitly declared
> disposable in git.**

- [x] **Backups paused for the parity check, then resumed — 2026-08-18/19.** Pausing 19 kopiur
      `SnapshotSchedule`s and 15 VolSync `ReplicationSource`s let the post-blackout check run
      uncontended, and it moved 1% → 23% → 50% → 79% once the array was left alone. All 34
      resumed 2026-08-19 19:07 UTC, ~5h before the 00:00 UTC window, with the check at 79%.

      Worth keeping for next time: the field is **`spec.schedule.suspend`** on kopiur, not
      `spec.suspend` — only the printer column reveals it — and `spec.paused` on VolSync.
      Flux manages neither, so patches persist across reconciles *and* never undo themselves.
      That cuts both ways: pausing is reliable, and forgetting to resume is silent.

      ⚠️ **`sbSyncErrs` is not a trustworthy running total.** It read 145 at 50% and 0 at 79%,
      and error counts do not decrease. The authoritative record is the line Unraid appends to
      `/boot/config/parity-checks.log` when a check completes (Aug 3 ended with 5, matching the
      July unclean stop). Read the result there, not from `/proc/mdstat` mid-flight.

      Disks checked while it ran and all healthy: parity `sdf` is **6.6 years** old (57,397 h)
      but has 0 reallocated and 0 pending sectors; both data disks 1.4 years, all counters
      clean. `mdNumInvalid=1` is the empty `parity2` slot, not a fault, and the cache NVMe
      showing `DISK_NP_DSBL` is present and mounted — the backups share is
      `shareUseCache="no"`, so backups never touch cache and it cannot explain the corruption.
- [ ] **Blocked until elizabeth's parity check finishes** (started 2026-08-18 after the
      unclean shutdown, 1% of 9.77 TB, historically 20-28h). The migration restores over NFS
      from the array that check is saturating, and two outages in two days is the wrong
      moment to be deleting and repopulating live PVCs.
- [x] **All 15 un-migrated apps protected in kopiur — 2026-08-18.** The 2026-08-17 blackout
      corrupted VolSync's repository mid-write and every mover died on a truncated index
      blob, leaving those apps with no backup for ~36h. Rather than wait for the repair, each
      got a `SnapshotPolicy` + `SnapshotSchedule` against its live PVC through
      `components/kopiur-external`. 19 policies now exist.

      This also **removes the damaged repository from the migration path entirely**: the
      snapshot each app takes here carries exactly the identity its component `Restore`
      resolves via `fromPolicy`, so migrating is now swap the component and recreate the PVC —
      no restore from `nas-volsync` at all. Verified against prowlarr's live objects.
- [x] **VolSync repository repaired — 2026-08-18.** 12 zero-length blobs, every one stamped
      01:30 on 2026-08-17: unifi-mongo's slot, the upload in flight when the power died. 3
      index blobs (kopia rebuilds those), 5 content blobs, 4 log blobs. Took a byte-exact
      safety copy first (`volsync-preblackout-20260818`, 17,374,345,979 bytes / 3,911 files,
      still holding the 12), deleted only zero-length files under the live repo, restarted
      `kopiur-controller` to reset the circuit breaker. `nas-volsync` back to
      `Ready/Bootstrapped`, radarr's manual sync completed, zero movers erroring.
      Full procedure in [AGENTS.md](AGENTS.md).
- [x] **All 19 apps have a working kopiur backup — 2026-08-20.** First full scheduled run
      after the blackout: **18 of 19 succeeded unattended** in their staggered 00:00–01:32 UTC
      slots, ~6.5 GB total. `unifi-mongo` among them at 766 MB, which is exactly what the
      `fsGroup` / `KOPIUR_PGID 999` work in phase 2's Task 1 existed for.

      **romm was the one failure, and the fix applied for it was wrong — corrected 2026-08-20.**
      It failed `PermissionDenied` on 29 files, and the conclusion drawn was that romm "runs as
      root and writes game-save uploads mode 0600, so a mover as 1000 cannot read them". The
      applied fix was `KOPIUR_PUID/PGID "0"` plus the namespace opt-in kopiur demands for an
      elevated mover.

      🔴 **That was backwards and it kept romm's backup broken for two days.** Every file and
      directory on the volume is owned by `1000:1000` — the note above even recorded
      "source ownership (already `1000:1000`)" and concluded the opposite. romm's *container* is
      root, but the app drops privileges and the `1000` group on the setgid dirs is not
      `fsGroup`. Since kopiur's mover drops **ALL capabilities**, uid 0 has no
      `CAP_DAC_OVERRIDE` and so loses the owner match without gaining a bypass. Proven both ways
      on the same volume minutes apart: `runAsUser: 0` → `PermissionDenied` on exactly those 29;
      `runAsUser: 1000` → `Succeeded`, **212,918,436 bytes** (against VolSync's 213,927,534).

      Caught only because the on-demand re-test was requested rather than trusting the two
      overnight failures as "historical". The override is removed, and so is the namespace
      privilege grant it required — nothing in `media` needs an elevated mover.
      `fsGroupChangePolicy` remains a dead end regardless: the mover snapshots a **read-only**
      clone Kubernetes cannot chmod.

      Procedure and both traps in [AGENTS.md](AGENTS.md), including the
      grep-across-document-boundaries mistake that made a namespace patch look as though it had
      landed on `kube-system`.
- [x] **karakeep deleted instead of migrated — 2026-08-20.** Unused, so it was removed rather
      than carried through the migration: manifests, Kustomization entry, Authelia OIDC client,
      both secret references, the leftover 5 Gi PVC and PV, and the two orphaned Bitwarden items.

      **It proved the deletion semantics, which are the opposite of what I first warned.**
      Deleting an app does **not** destroy its backups: `onScheduleDelete` and `onPolicyDelete`
      both carry a *schema* default of `Retain`, so pruning the schedule garbage-collects the
      `Snapshot` CRs while the kopia snapshots survive. Both of karakeep's came back as
      `origin: discovered`, `deletionPolicy: Retain`, identity `/pvc/karakeep`, `75,429,492`
      bytes — the exact figure the schedule recorded. Two traps on the way: discovered snapshots
      are named `<repo>-disc-<hash>` and carry `origin` as a **label**, and the catalog needs an
      explicit `catalog-scan-requested-at` annotation or they never materialise at all.

      ⚠️ Also proved that **Flux does not remove an app's PVC** when the app is pruned — it
      stayed `Bound` with an empty `deletionTimestamp`. Deleting an app is not finished until
      `kubectl get pvc,pv -A | grep <app>` is empty. Both in [AGENTS.md](AGENTS.md).
- [ ] **Batch 2 in progress 2026-08-20: pyload-ng, radarr, sonarr done; qbittorrent left
      deliberately.** 4 of 19 → 7 of 19 on kopiur. Its Kustomization is Ready and the app runs
      on its old PVC, because the `ssa: IfNotPresent` label stops Flux touching it — a stable
      resting point, not a half-migration.

      **13 volumes migrated as of 2026-08-20**, confirmed by `dataSourceRef.kind == Restore`:
      metube, prowlarr, pyload-ng, qbittorrent, radarr, sonarr, esp-home, home-assistant,
      jellyseerr, romm, unifi-mongo, filebrowser, ocis. Remaining: **unifi** (in progress),
      **frigate**, **jellyfin**, **paperless** — all three still on
      `dataSourceRef: ReplicationDestination/<app>-dst`, backed up by kopiur but not yet moved —
      and **vaultwarden**, deliberately last and alone, the only app left with a live VolSync
      `ReplicationSource`.

      🔴 **unifi exposed a Flux deadlock worth knowing about, and the obvious fix did not
      work.** unifi-mongo's Kustomization has `wait: true`, and it wedged at `Ready=Unknown`
      reporting `[Restore/network/unifi-mongo status: 'InProgress']` while that Restore had been
      `Completed` for 45 hours. `InProgress` is not one of its phases — it is kstatus's verdict
      when `observedGeneration` lags `generation`, and a `Restore` stops reconciling once
      terminal, so the re-apply that bumped it to generation 2 was never observed. The health
      check could never pass and **unifi was gated behind it indefinitely**, its pod `Pending`
      with no PVC while its own status said only "dependency not ready".

      **It is systemic:** all 12 other migrated Restores carry the identical `gen=2 / obsGen=1`
      lag. `wait: false` only hides it, so any app ever given `wait: true` breaks the same way.

      `healthCheckExprs` reading `status.phase` was the obvious fix and it **does not work** —
      with the exprs live the verdict was identical after a full 10-minute window, because
      kstatus applies the generation precondition before evaluating the CEL. Isolated by patching
      `status.observedGeneration` alone, after which the Kustomization went Ready on the next
      reconcile. The durable fix is an explicit `healthChecks` entry on the HelmRelease with
      `wait: false`, which keeps the real gate (helm-controller waits for the workload) without
      health-checking the Restore. Worth reporting upstream as a kopiur bug.

      unifi itself then migrated cleanly: **22 files, verified identical** against the
      pre-migration manifest before the app was allowed to start. **14 of 18.**

      **The procedure got much simpler.** Every app now has its own kopiur snapshot, so the
      damaged VolSync repository is out of the path entirely: stop → quiesced kopiur snapshot →
      delete the PVC → Flux recreates it → the populator restores via `fromPolicy`. No manual
      `Restore` object at all. pyload-ng came back byte-identical, 17 files.

      🔴 **radarr lost ~7 hours of metadata, and it was a tooling error, not a kopiur one.** A
      `delete pvc` from a call that timed out stayed **armed** behind the pvc-protection
      finalizer, and fired when a later run stopped the pod. Recovered from the 00:08 scheduled
      snapshot — **5510 files, 1.7 G, identical count and size** — losing only changes since
      then. Three flaws found and fixed, all in [AGENTS.md](AGENTS.md):

      - a blocked `delete pvc` is armed, not cancelled — check `deletionTimestamp` first
      - **KEDA scales apps back up through a suspended HelmRelease**, defeating the verification
        gate and holding the PVC open. 8 apps carry `nfs-scaler`; pause the `ScaledObject`
      - a verification manifest must wait for its pod to reach `Succeeded` — reading logs early
        truncated a 5510-file baseline to 493 and would have "verified" a partial volume

      Also expect **one benign difference per app**: its own log file. The CSI snapshot is
      crash-consistent so the tail differs; sonarr's diff was exactly that, 1 line of 798.
- [x] **ALL 18 apps migrated — 2026-08-20.** Every PVC now carries
      `dataSourceRef: Restore`, there is not one `ReplicationSource` left in the cluster, and no
      `ks.yaml` references `components/persistence`. Each app was gated on a per-file checksum
      manifest of the quiesced volume against the restored one before being allowed to start:

      | batch | apps | verification |
      | --- | --- | --- |
      | 1 (08-16) | metube, jellyseerr, filebrowser | 9 / 2 / 2 files |
      | 2 (08-20) | prowlarr, pyload-ng, radarr, sonarr, romm, esp-home, qbittorrent, ocis, unifi-mongo, home-assistant | incl. romm 9,701 and radarr 5,510 |
      | 3 (08-20) | frigate, jellyfin, paperless, unifi | 4 / 18,521 / 108 / 22 files |
      | 4 (08-20) | vaultwarden — last and alone | 487 files, 4,869,112 bytes |

      vaultwarden needed `KOPIUR_CAPACITY: 1Gi` stated explicitly: it defaults to **5Gi**, so
      leaving it unset silently grows a 1Gi volume on migration. Its snapshot came out
      byte-identical to both scheduled ones, which is what made the content provably stable.

      The four orphaned `ReplicationDestination` objects Flux will not prune (qbittorrent,
      home-assistant, node-red, karakeep) are deleted. **VolSync now has zero workload objects.**
- [ ] Migrate the remaining 18 VolSync apps to kopiur, in batches, not in bulk.
      **Batch 1 done 2026-08-16 — metube, jellyseerr, filebrowser**, each verified by diffing
      a per-file checksum manifest of the quiesced volume against the restored one:
      identical, 9 / 2 / 2 files. First kopiur snapshots `Succeeded` at 21,007,083 / 13,966 /
      65,666 bytes. 4 of 19 apps now on kopiur.

      Two runbook corrections the pilot forced, both silent failures:

      - `flux resume hr` does **not** restore replicas — app-template leaves `replicas` unset,
        so Helm keeps the `0` and the HelmRelease reports success with no pods
      - there is **no trigger annotation** on `SnapshotPolicy`; an on-demand run is a
        `Snapshot` CR with `policyRef`, and it reports `Succeeded`, not `Completed`

      Also: the discovered `Snapshot` CRs are a cache from when `nas-volsync` was deployed, so
      their newest entry lags what VolSync has actually written. Judge freshness from
      `replicationsource.status.lastSyncTime`; `offset: 0` reads the live repository regardless.
- [x] Delete each app's orphaned `ReplicationDestination` by hand — Flux will not prune it.
      Done 2026-08-20: all four gone, no VolSync object of any kind left in the cluster.
- [ ] Two leftover `premigrate` snapshot CRs (`downloads/qbittorrent`, `home/home-assistant`) from
      runs that aborted before their cleanup step, plus `media/romm-fixcheck2` — left in place
      deliberately: they are valid pre-migration copies, and `romm-fixcheck2` is romm's only
      *post-fix* backup until the 00:40 UTC run. Delete once that run succeeds. Also still there:
      the `downloads/prowlarr-rescue` PVC (2Gi, 8 days old) — flagged rather than deleted, since
      the standing rule is to keep cold fallbacks through phase 3
- [x] **All four unprotected PVCs now backed up — 2026-08-20.** `services/paperless-ai`,
      `observability/grafana-pvc`, `database/mosquitto`, `database/pgadmin`, each via
      `components/kopiur-external` (backup half only — every one of these PVCs is created by a
      chart, an operator or its own `pvc.yaml`, and `dataSourceRef` is immutable so none can be
      adopted in place). Slots staggered into the free 5-minute gaps: 00:50, 01:35, 01:40, 01:45.

      **The mover UID was measured per app, not inferred** — the mistake that broke romm. All four
      differ, and three of the four would have failed on a guess:

      | app | ownership | mover | first run |
      | --- | --- | --- | --- |
      | grafana | all `1000:1000` | default 1000 | 49,531,555 B |
      | mosquitto | 284 files `1000:1000 0600` | default 1000 | 85,148 B |
      | pgadmin | `5050:5050`, 10 files `0600` | **5050** | 401,408 B |
      | paperless-ai | root-owned but `644`/`755` | default 1000 | 262,994 B |

      Each was proven with an on-demand run rather than left for the schedule.

      paperless-ai needed one manual fix: an empty ext4 `lost+found` at `0700 root:root` blocked
      traversal. Set to `2770` group 1000 (the shape mosquitto's already had). The alternative was
      a root mover, which needs `privileged-movers` on the **services** namespace — the one that
      holds vaultwarden. Not worth it for one empty directory.

      ⚠️ pgadmin also lost `wait: true`, which cannot coexist with the inert `Restore` this
      component adds: nothing claims it, so kstatus holds it `InProgress` forever. Replaced with
      an explicit HelmRelease health check.

      **Still open for phase 3:** none of these four sets `dataSourceRef` on its PVC, so a
      rebuilt cluster would bring them up **empty and reporting healthy** — which G4 counts as a
      bug. Backups protect the data today and can be restored by hand; the automatic-restore half
      needs each chart to expose `dataSourceRef` (mosquitto's own `pvc.yaml` and grafana's CR can,
      app-template's `persistence` needs checking).
- [x] **Every PVC now has declared intent, and `just backup-audit` enforces it — 2026-08-20.**
      [backup-policy.yaml](backup-policy.yaml) at the repo root, checked by
      [scripts/backup-audit.sh](scripts/backup-audit.sh). 50 live PVCs = 22 protected by kopiur +
      28 declared exceptions, and the audit exits clean.

      The file lists **only the exceptions**. "Protected" is derived from the live
      `SnapshotPolicy` objects, so there is one source of truth for what is backed up and the
      file cannot drift out of agreement with the cluster. The rule enforced is simply: every
      live PVC is either named by a policy or listed as an exception — which is the gap that let
      `paperless-ai` run four months with no backup while looking healthy.

      It checks the two failure modes that *look* like success:

      - **unclassified** — a PVC nobody ever considered (the paperless-ai mode)
      - **protected but not producing** — a policy that exists but whose newest snapshot is
        `Failed`, missing, or older than 48h (the romm mode: two days of `PermissionDenied`
        while the SnapshotPolicy sat there looking fine)

      plus contradictions: an exception something is actually backing up, a stale entry whose PVC
      is gone, and a policy naming a PVC that does not exist. It refuses to report clean without
      cluster connectivity, since a failing `kubectl` would otherwise read as "no PVCs exist".

      **Both detection paths were tested, not just the green run:** removing the four
      observability entries produced exactly 4 findings and exit 1; `MAX_AGE_HOURS=0` flagged 18
      of 22 — correctly excluding the 4 whose snapshots were 0 hours old.

      🔴 Found while building it: `// empty` is jq syntax and yq rejects it outright. With
      `2>/dev/null` on that call the exception list parsed as empty and the audit reported **28
      confident false findings**. The suppression is gone and a policy file that parses to
      nothing while containing entries is now a hard error.
- [x] **Observability history: decided NOT to back up — 2026-08-20**, on the numbers rather than
      by default. prometheus is **16 GB in use** against a **7.0 GB total repository**, and its
      content self-expires at 14d retention, so a restore would recover metrics already partly
      stale; victoria-logs is the same argument at 14d. alertmanager is only 40 KB, but its one
      piece of real state is silences — and all 4 are declared in git under
      `silence-operator/silences`, so it is reconstructible. `config-gatus-0` holds only probe
      history; its config comes from git. All four are declared `disposable` with reasons.
- [ ] ⚠️ **Leave CNPG data and WAL out of kopiur.** `cluster18` and `immich-db` carry Authelia,
      paperless, atuin and immich metadata. A filesystem snapshot of a live Postgres, with WAL
      on a *separate* PVC snapshotted at a different instant, is inconsistent — barman is the
      only correct mechanism. Nightly barman backups complete (verified 2026-08-12 and -13)
- [x] **VolSync and the `perfectra1n` fork retired — 2026-08-20.** Removed
      `apps/volsync-system/volsync` (app + maintenance) and the now-dead `components/persistence`,
      then deleted the three orphaned `volsync.backube` CRDs Helm leaves behind (0 instances
      each). No VolSync API surface remains.

      Three things depended on it and were fixed rather than left to break:

      - **tuppr** — *both* upgrade CRs gated node reboots on "no `ReplicationSource` is
        Synchronizing". Translated to the kopiur equivalent so a node is still never
        powercycled mid-backup. Gated on `status.phase`, **not** conditions: discovered
        snapshots carry no `conditions` field and there are 400+ of them, so a conditions
        filter would have matched nothing on every one
      - **`volsync-system/kopia`** — the read-only browser for the retired repository. It never
        needed the operator (the `volsync` hostname in its config JSON is kopia source
        metadata), and it is how the cold archive stays readable
      - **`home/immich`** — a stale `dependsOn`; its PVCs are cache/NFS so it just loses it
- [ ] Keep the old repository as a cold fallback **through phase 3**, then delete it.
      Active: the `volsync-repo` ClusterRepository and the data on elizabeth are both kept, and
      the `kopia` UI reads them. Its `KopiaMaintenance` went away with the operator, which is
      fine for a read-only archive — maintenance compacts indexes, it is not needed to read
- [ ] Delete the leftover pre-migration rescue PVCs, `prowlarr-rescue` included — they are
      deliberately kept through this phase as known-good references
- [x] **The CNPG monitoring gap was worse than noted, and is fixed — 2026-08-20.** The note said
      "anything alerting on it is blind". There *was* such an alert, `DatabaseFailedBackup`, and
      it could **never fire**: it compared against `cnpg_collector_last_successful_backup_timestamp`,
      a metric the barman-cloud plugin never emits. A PromQL comparison against an absent vector
      yields an **empty result** — not an error, not false — so the rule looked correct, stayed
      silent, and was never suspected.

      Rewritten onto `cnpg_collector_last_failed_backup_timestamp`, which *does* carry real data
      (`immich-db-1` = Aug 19 23:57:30 UTC, `cluster18-2` = Aug 3 00:01:40 UTC — both matching
      known failures). Verified by evaluating both expressions against the live series: the old
      returns 0 series, the new returns `database/immich-db-1`.

      Also confirmed genuinely blind and left commented with the reason, so nobody re-derives it:
      `last_available_backup_timestamp` and `first_recoverability_point` are pinned at **0** on
      all four pods. A working "no recent backup" check must read the `Backup` objects, not
      metrics.

      ⚠️ Method note: my first pass concluded "no CNPG metrics are scraped at all" — that was
      wrong and came from `kubectl exec … wget` failing silently (no `wget` in the prometheus
      container). **90 `cnpg_` metrics are scraped.** Query Prometheus through the API proxy
      (`kubectl get --raw /api/v1/namespaces/observability/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/...`)
      rather than exec, and sanity-check with `up` before trusting a "no data" result.
- [ ] 🔴 **OPEN: MinIO on elizabeth is flapping, and it is why immich-db has no base backup
      since 2026-08-18.** Diagnosed 2026-08-20. Not a CNPG problem and not immich-specific — the
      object store itself is degraded:

      ```
      ListObjectsV2 → InternalError ... cause(listPathRaw: 0 drives provided)
      node(127.0.0.1:9000): Read/Write/Delete successful, bringing drive /data online
      .minio.sys/buckets/.usage-cache.bin has incomplete body (cmd.IncompleteBody)
      ```

      MinIO repeatedly marks its single backing drive **offline**, then heals it, then loses it
      again. Every base backup begins with a LIST, so it fails whenever the drive is down —
      while WAL archiving is a PUT and mostly squeezes through (75 archived / 7 failed). That
      asymmetry is the whole reason this looked immich-specific: `s3://postgresql/` fails the
      **identical** way, and cluster18's 2026-08-19 backup only completed because it happened to
      catch an online window.

      **Cause: elizabeth was shut down uncleanly on 2026-08-19 16:29** — `/boot/config/forcesync`
      is stamped at exactly that minute, the same marker as the 2026-07-29 unclean stop. That
      triggered an automatic *correcting* parity check which found and fixed **145 sync errors**
      (39.9 h wall-clock with the tuning plugin's pauses, 32,222 s of actual sync, done
      2026-08-20 01:27 UTC), and left MinIO's internal metadata damaged — the `IncompleteBody`
      on its usage cache is the same class of truncation as the kopia zero-length blobs from the
      2026-08-17 blackout.

      Hardware is **not** implicated: `sdg` (disk2) SMART PASSED, 0 reallocated, 0 pending, 0
      offline-uncorrectable; only 7 historical UDMA_CRC errors.

      Impact: WAL is archiving with **no base to replay onto**, so no PITR for immich's metadata
      since Aug 18. Not urgent by disk — WAL volumes sit at 3–5%.

      Next step is a MinIO restart to clear the stuck offline state and rebuild the usage cache
      (deliberately NOT done unattended - it is a service on the shared NAS), then re-run both
      clusters' backups and confirm `barman-cloud-backup-list` shows a fresh entry for
      `immich-pg17-0`.

      🔬 Method notes worth keeping. The plugin wraps everything as
      `rpc error: exit status 1` and neither the plugin Deployment nor the `Backup` object
      carries barman's stderr. Two things made it findable: CNPG runs backups on the **replica**
      by default (the operator log names the pod - I was reading the primary's log and seeing
      nothing), and `barman-cloud-backup-list` run from a throwaway pod using the same image
      reproduces the real S3 error in one shot. Feed credentials with `secretKeyRef`, never on a
      command line.

Phase 2 produced the numbers this phase needs: snapshot 111 s and restore+bind 34 s on a 1 GiB
volume, a 3.3 MB repository for prowlarr's 57 MB, and a scheduled run that fired unattended.
What it did **not** produce is behaviour at 45 apps at once — so batches, not bulk.

### Phase 2.6 — node self-recovery: hardware watchdog and kernel logs — ⚠️ priority, inserted 2026-08-18

**Independent of 2.5**: this touches only Talos machine config, so it does not wait for the
kopiur migration to finish.

**What revealed it.** On 2026-08-18 `kube-ceph-03` stopped answering at 19:31 CEST — every
scrape target died in the same interval, no ICMP, no Talos API, no ARP entry. It was healthy
60 s earlier (44-48 °C, 6.9 GB RAM free, load 1.3, zero OOM kills, 14.8 GB free on `/var`),
and `Wake-on: g` is armed on these NICs, yet WOL from a peer on the same VLAN did nothing. A
powered-off machine with WOL armed would have woken, so the board was almost certainly still
running with a dead network path.

Cost of that single hang: ~3 h down, Ceph pinned at 33 % degraded (it cannot re-replicate with
three OSD hosts and `size 3` — phase 3 removes Ceph entirely), nine RBD volumes stranded on a
node Kubernetes would not release, and a physical trip to press a button.

**The cause is still unknown, and that is the actual problem.** Nothing ships kernel logs off
these nodes, so `Detected Hardware Unit Hang`, a panic trace or an MCE all vanish on reboot.
The `e1000e`/I219 hang is the obvious suspect and `tx-tcp-segmentation: false` is already
applied and live on all five nodes — but `node_network_carrier_changes_total` and the tx/rx
error counters were flat at **0** through the 30 min before death, which is not what a
driver-reset loop looks like. Without logs it stays a guess. Same shape as the elizabeth
syslog gap in Follow-ups: no evidence retained, so every recurrence is equally unexplainable.

Verified on a live node, 2026-08-18:

| check | state |
|---|---|
| `/dev/watchdog0` | present (Intel PCH) |
| `WatchdogTimerConfig` / `WatchdogTimerStatus` | both empty — **the watchdog is unused** |
| `panic=` / `pcie_aspm` / `intel_idle.max_cstate` in `/proc/cmdline` | none set |
| `machine.logging.destinations` | not configured |
| EDAC (RAM error) metrics | absent, so RAM errors are invisible |

- [ ] Enable the Talos **hardware watchdog** (`WatchdogTimerConfig`, against `/dev/watchdog0`).
      The device exists and nothing arms it. If the kernel stops petting it the board resets
      itself, turning "hangs until someone drives over" into a ~1 min reboot — and it works
      whether the cause is the NIC, the kernel or RAM
- [ ] Add `panic=10` to [machine-kernel.yaml](kubernetes/talos/patches/global/machine-kernel.yaml)
      so a panic reboots instead of sitting dead
- [ ] Ship kernel and service logs off-node via `machine.logging.destinations` into
      VictoriaLogs. fluent-bit collects *container* logs only, which is exactly why this
      incident left no kernel evidence. Verify the schema against Talos 1.13 first
- [ ] Export **EDAC** counters, so a single-bit RAM error — which hangs a box in precisely
      this way — stops being invisible
- [ ] Alert on `node_network_carrier_changes_total` rising: it catches a flapping NIC *before*
      a full hang, and its being flat at 0 is what weakened the e1000e theory here
- [ ] **Fix the NUT alert rules.** The UPS is currently reporting `ups.status: ALARM OL CHRG` with
      `ups.alarm: "Battery voltage too low!"` at `battery.charge: 100`, and **nothing alerts on it**:
      the rules in [prometheusrule.yaml](kubernetes/apps/observability/nut-exporter/app/prometheusrule.yaml)
      only cover `OB`, `RB`, `charge < 50` and runtime-while-`OB`. This is the actual reason Unraid
      warned for months while the cluster stayed silent. The exporter already runs with
      `--nut.vars_enable=` so every variable is exported and these alerts cost nothing but rules:
  - [ ] `network_ups_tools_ups_status{flag="ALARM"}` — the condition that was missed
  - [ ] `ups.test.result` — battery self-test outcome, watched by nothing today
  - [ ] `ups.load` and `battery.runtime` **while on line power** — `UpsLowRuntime` only evaluates
        once already on battery, so it can never warn *before* an outage
  - [ ] `battery.charge` failing to return to 100 after a discharge, and `battery.voltage`
  - [ ] Raise the scrape rate or drop `for:` on flag-based rules — a 60 s scrape with `for: 10s`
        needs the flag present in two consecutive samples to fire

⚠️ **Do not set `hung_task_panic=1`.** It looks like the natural companion to `panic=10` and it
is wrong for this cluster: phase 1.5 documents stale NFS handles from elizabeth, and that flag
would turn an NFS stall into a node reboot. The hardware watchdog covers the genuinely-dead
case without that false positive.

**Only if it recurs, and one change at a time** — applied together, you never learn which one
mattered: EEE off (a known I219 trigger that TSO-off does not cover), `pcie_aspm=off`,
`intel_idle.max_cstate=1` (costs idle watts, which the UPS budget notices), NIC/BIOS firmware
(currently `0.5-4`).

**Operational lesson, worth more than the config.** To evict a dead node, taint it **before**
deleting it:

```bash
kubectl taint node <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
```

Modern Kubernetes deliberately no longer force-detaches volumes when a Node object is deleted.
Deleting the Node first orphans its `VolumeAttachment`s with `deletionTimestamp: null` and no
controller left to clean them, and they must then be removed by hand before any RWO volume can
attach elsewhere. Before forcing any RBD detach, prove no stale client holds the image:
`rbd status <pool>/<image>` must show no `watcher=` from the dead node.

### Phase 2.7 — replace MinIO with garage, and make barman's target trustworthy

**Moved ahead of the rebuild on 2026-08-20**, after the MinIO incident. The original reasoning
for putting this after phase 3 was that "the target only makes sense once the storage layer is
settled, and doing it earlier would mean migrating barman's backend twice" — that no longer
applies, for two reasons:

- garage is going on **elizabeth**, not in the cluster, so the rebuild does not touch it. There
  is no second migration to avoid
- the incident showed the current target is not merely inelegant, it is **actively unreliable**.
  An unclean shutdown on 2026-08-19 left MinIO with a stuck offline drive; every immich-db base
  backup failed for **two days** and nothing alerted, because the only alert that could have
  caught it was comparing against a metric that does not exist. Phase 3's G2 gate — a rehearsed
  barman restore — cannot honestly be earned against a backend in that state

So this now runs **before** the rebuild, and G2 gets rehearsed against garage rather than
against MinIO.

**Resolved 2026-08-20:** MinIO was restarted, its drive came back online, and immich-db produced
`backup-20260820192847` in 1m49s — the first base backup since Aug 18. The immediate gap is
closed, which is what makes this a planned migration rather than an emergency.

**What garage is.** A self-hosted S3-compatible object store (Rust, by Deuxfleurs) built for a
handful of cheap, unreliable, geographically-scattered nodes rather than a datacentre —
replication rather than erasure coding, no central metadata server, and a footprint measured in
hundreds of MB. A lighter alternative to MinIO or Ceph RGW when all that is wanted is an S3
endpoint. eleboucher/homelab runs it with `garage-operator`, so there is a working reference.

**Why it is worth doing.** CNPG's barman backups are the one recovery path kopiur cannot cover
— phase 3's G2 gate exists for exactly that — and today they target **MinIO on elizabeth**, the
host whose stale NFS handles are parked as phase 1.5 and whose parity checks saturate it for a
day at a time. The most critical backup in the cluster depends on the least reliable machine.

⚠️ **The trap to settle before any of this: do not put the cluster's disaster-recovery backup
inside the cluster it protects.** If garage runs on miroir and the cluster is gone, barman
cannot be reached to restore it — the dependency is circular and only shows up on the day it
matters. Two shapes avoided it, and **the first was chosen** (2026-08-20):

- ✅ garage on the **Docker hosts** (donkey / navi / elizabeth) via doco-cd, outside the cluster.
  Keeps DR independent, uses the geo-distributed design garage is built for
- ✗ garage **in-cluster** for ordinary object storage, with barman replicating to a second
  off-cluster target. More moving parts, and the second target does the real work anyway

**Garage vs MinIO on Unraid — checked against both projects' docs, 2026-08-20.** An earlier
draft of this section claimed garage would hit "the same trouble" and blamed the mover plus
LMDB's use of mmap. Both framings were wrong; corrected here.

**What actually blocks MinIO on `/mnt/user`** is not the mover — it is shfs itself. MinIO's docs
state *"MinIO AIStor requires the XFS filesystem for best performance and behavior at scale"* and
that *"using any other type of backing storage (SAN/NAS, ext4, RAID, LVM) typically results in a
reduction in performance, reliability, predictability, and consistency"*. `/mnt/user` is a FUSE
overlay, so it fails that requirement whatever the cache setting is. `/mnt/disk2` is real XFS
(`/dev/md2p1 ... type xfs`), so pinning there satisfies the documented requirement. The mover is
a *separate* hazard, and verified absent here: `atlantic_minio` and `backups` are both
`shareUseCache="no"`, and the `0 4 * * *` mover only touches the `yes` shares.

**Garage is not a MinIO fork.** Independent implementation by Deuxfleurs, in production since
2020, AGPLv3, **95.1% Rust** (MinIO is Go). Architecturally different on purpose: it uses
**replication and explicitly rejects erasure coding** (*"erasure coding … increase the difficulty
of placing data and synchronizing; we limit ourselves to duplication"*), keeps metadata in a
separate DB engine rather than beside the objects, and lists **POSIX filesystem compatibility as
an explicit non-goal**.

**So its requirements are softer than MinIO's, and about integrity rather than fs features.** No
documented XFS requirement, no NAS prohibition, nothing about xattr or O_DIRECT. What the docs do
say:

- metadata: *"Garage does not do checksumming and integrity verification on its own, so it is
  better to use a robust filesystem such as BTRFS or ZFS"*
- data: *"Garage already does checksumming and integrity verification … We recommend using XFS
  for the data partition"*; ext4 discouraged on inode limits
- ⚠️ the real hazard, and it is exactly elizabeth's demonstrated failure mode: *"when using the
  LMDB database engine (the default), database files have a tendency of becoming corrupted after
  an unclean shutdown (e.g. a power outage), so you should take regular snapshots"* — or switch
  to **SQLite**, which *"does not have the issues listed above for LMDB"*

**Elizabeth happens to have an ideal layout for it**, which MinIO cannot exploit because it has
no metadata/data split: `metadata_dir` on `/mnt/cache` — **btrfs on NVMe, 218 GB free**,
checksumming and snapshot-capable, reached via a `shareUseCache="only"` share the mover never
moves — and `data_dir` on `/mnt/disk2` (XFS). That satisfies every documented recommendation.

**In-cluster the shfs question disappears**, and metadata on Ceph RBD / miroir block storage is
fine — but the LMDB unclean-shutdown warning follows garage everywhere, so either take metadata
snapshots or run the SQLite engine regardless of where it lands. Never put the metadata on an
NFS volume.

#### Decided: garage on elizabeth (Unraid). The layout, and why

Prior art exists but is thin: one documented Unraid write-up (geiser.cloud, "Deploying Garage S3
v2.x and Hooking It Up to Duplicacy") using `/mnt/user/appdata/garage/garage.toml` for config and
`/mnt/user/my_disks/garage` for **both** meta and data, plus `garage-webui` alongside. No
Community Applications template found. Note that write-up puts **metadata on `/mnt/user`**, which
is the one choice to avoid — see below.

⚠️ **`db_engine = "sqlite"` is necessary but NOT sufficient.** From garage issue #1200, the
maintainer's own diagnosis of a malformed-database report: corruption comes from *"a combination
of factors, for example: unclean shutdown (power loss) + non-resilient filesystem"*, and he
classifies **BTRFS/ZFS as resilient, ext4 and XFS as non-resilient**. So SQLite on an XFS array
disk is still exposed to exactly what has happened here twice. Engine *and* filesystem both have
to be right.

The layout that satisfies every documented requirement, verified on the box:

| dir | path | why |
| --- | --- | --- |
| `metadata_dir` | `/mnt/cache/appdata/garage` | btrfs on NVMe — "resilient" per the maintainer, snapshot-capable, 208 GB free. **Direct `/mnt/cache` path, not `/mnt/user/appdata`** |
| `data_dir` | `/mnt/user/backups/garage` | shfs is fine here: garage *"already does checksumming and integrity verification"* on data, blocks are write-once, no locking, no mmap. `shareUseCache="no"` so the mover never touches it |

**The `/mnt/user` distinction is the whole point and it is easy to get wrong**: `appdata` is
`shareUseCache="only"` so its data never leaves the pool — but the *path* `/mnt/user/appdata`
still traverses shfs. SQLite over FUSE is the classic source of "database disk image is
malformed" (advisory locking plus fsync semantics), so the metadata path must be `/mnt/cache/…`
directly. Cache-disabled is not the same as FUSE-free.

Also take **btrfs snapshots of `metadata_dir`** — garage prescribes exactly that, and the cache
pool makes it cheap.

Two non-filesystem caveats found while checking:

- `backups` has `shareInclude=""` with the `highwater` allocator, so data written through
  `/mnt/user/backups` **can spread onto disk1, which is 86% full**. Pin it via `shareInclude`, or
  give garage its own share
- putting garage's data in the same share as the kopiur repository means **one disk loss takes out
  both backup systems** — they are already both on disk2. A correlated failure worth choosing
  deliberately rather than inheriting

🔴 **The cost accepted by choosing elizabeth, stated plainly.** The MinIO failure was not the
mover and not the disk (`sdg` SMART PASSED, 0 reallocated/pending). It was elizabeth being shut
down **uncleanly — twice in three weeks** (2026-07-29 and 2026-08-19), each time triggering a
multi-hour correcting parity check, and the second time silently breaking every base backup for
two days. Keeping DR on elizabeth escapes the circular dependency but accepts a machine with a
demonstrated unclean-shutdown habit — which is precisely why `db_engine = "sqlite"`, a btrfs
`metadata_dir` and metadata snapshots are **all three** required below rather than optional.

⚠️ **Whatever is stopping elizabeth uncleanly is a separate open problem**, and garage will not
fix it. Two unclean stops in three weeks is the root cause behind both this migration and 145
corrected parity errors; worth chasing on its own.

Sizing: barman already holds **88 GB** (`postgresql` 23 GB + `immich` 65 GB) of 101 GB total
MinIO data, and grows. That ruled **donkey** out despite it being the natural DR host on battery
+ LTE, and navi out on the same grounds — leaving elizabeth. Also worth knowing: disk1 is **86%
full**, and both MinIO's data and the kopiur repository (6.3 GB) sit on the same physical disk,
disk2.

- [x] **Shape decided 2026-08-20: garage on elizabeth via doco-cd**, replacing MinIO in place
      rather than running in-cluster. It keeps DR outside the cluster it protects, and the
      rebuild cannot disturb it. The circularity trap above is what rules the in-cluster option
      out for barman specifically; ordinary in-cluster object storage remains a separate question.

#### Adoption plan

Sequenced so the current backup path keeps working until the new one has been *restored from*,
not merely written to. Nothing is cut over on the strength of a successful write.

- [ ] **Give garage its own Unraid share**, cache disabled, rather than reusing `backups`. Two
      reasons found while checking: `backups` has `shareInclude=""` with `highwater` allocation
      so data written through `/mnt/user` can spread onto disk1 (**86% full**), and colocating
      with the kopiur repository would put **both backup systems on one disk**
- [ ] **Deploy garage via doco-cd** as a per-host compose service (donkey/elizabeth/navi pattern
      already exists), pinned to a digest, with the layout settled above:

      ```toml
      metadata_dir = "/mnt/cache/appdata/garage"   # btrfs NVMe, direct path, NOT /mnt/user
      data_dir     = "/mnt/user/<garage-share>"    # shfs is fine: garage checksums data itself
      db_engine    = "sqlite"                      # LMDB corrupts on unclean shutdown
      replication_factor = 1                       # single node; be explicit about it
      ```

      ⚠️ `metadata_dir` must use the **`/mnt/cache` path, not `/mnt/user/appdata`** — cache-only
      is not the same as FUSE-free, and SQLite over FUSE is the documented way to get "database
      disk image is malformed"
- [ ] **Schedule btrfs snapshots of `metadata_dir`** — garage prescribes exactly this, and it is
      the only mitigation that covers the failure mode elizabeth has actually demonstrated twice
- [ ] Create buckets and access keys for barman (`postgresql`, `immich`), and a second
      `ObjectStore` per cluster pointing at garage. **Keep MinIO serving in parallel** — CNPG
      supports only one plugin objectstore per cluster at a time, so this is a cutover, not a
      dual-write; the parallel period is for rehearsal, not redundancy
- [ ] 🔴 **Rehearse a real barman restore from garage before switching anything**, for *both*
      clusters, and re-earn phase 3's G2 gate against it. A backup target that has never been
      restored from is a hope. This is the gate — not the write succeeding
- [ ] Cut `cluster18` over first (smaller, 23 GB, and immich is the one that just broke), verify
      a **scheduled** backup and a WAL archive both land, then `immich-db`
- [ ] Watch for one full week with `DatabaseFailedBackup` armed — it works now, and it is the
      only reason a repeat of the Aug 19 failure would be noticed
- [ ] Only then retire MinIO, and write down what still points at elizabeth
- [ ] Decide what happens to the **101 GB of MinIO data** on retirement: the old barman history
      is the pre-garage recovery path, so keep it read-only until garage has a restore rehearsal
      *and* a week of clean scheduled backups behind it
- [x] Fix the monitoring gap while here — **done early, 2026-08-20**, because it was what hid the
      immich-db failure. `DatabaseFailedBackup` could never fire; rewritten onto
      `cnpg_collector_last_failed_backup_timestamp`. Details in phase 2.5


### Phase 3 — the rebuild: destroy the cluster, drop Ceph, rename the nodes

One planned outage that fixes four things at once, none of which can be fixed in place:
Ceph goes away, the nodes get honest names, etcd gets a third member, and the disk layout
stops being backwards.

**Approach: big bang.** Reset all five nodes and rebuild from git. The alternative — moving
data onto miroir loopfiles first, deleting Ceph, then rebuilding node by node — avoids the
outage but costs a second data hop, and it cannot fix the partition layout without wiping
every system disk anyway. Chosen deliberately: **once the disks are wiped there is no
rollback except restore**, which is exactly why phase 2.5's exit condition is what it is.

**The framing that makes this worth doing:** you do not currently know that this cluster can
be rebuilt — you have the hope of it. Better to find the gaps at a chosen hour than during a
real failure. And **phase 2.5 is the rehearsal**: migrating an app to kopiur *is* recreating
its PVC and repopulating it from backup, so by the end every app's restore has been proven
individually. Phase 3 is doing all of them at once.

#### Why the disks force the design

miroir needs the disks Ceph is sitting on, so the two cannot coexist on final hardware.
Hardware, measured 2026-08-14:

| node | new name | model | system disk | data disk |
|---|---|---|---|---|
| 10.1.10.10 | `kube-nuc` | Intel NUC10i5FNH, 8 cpu / 32 GB | 500GB Samsung 970 EVO+ | — single disk |
| 10.1.10.11 | `kube-hp` | HP EliteDesk 800 G4 DM, 6 / 16 | 256GB WDC SN720 | — single disk |
| 10.1.10.21 | `kube-m720-01` | ThinkCentre M720q, 6 / 16 | 120GB KINGSTON SA400S3 | 1TB Crucial P3 |
| 10.1.10.22 | `kube-m720-02` **(new CP)** | ThinkCentre M720q, 6 / 16 | 256GB SanDisk SD9TB8W2 | 1TB WD_BLACK SN850X |
| 10.1.10.23 | `kube-m720-03` | ThinkCentre M720q, 6 / 16 | 256GB SanDisk SD9TB8W2 | 1TB WD_BLACK SN850X |

**Third control plane is `kube-m720-02`, not -01.** All three M720q are identical on CPU and
RAM, so the disks decide: etcd is fsync-latency-bound and the **KINGSTON SA400S3 is DRAM-less
consumer SATA**, the worst disk here for that. The Crucial P3 is also QLC with lower endurance
than the SN850X. Names map by IP so the addresses stay put — DHCP, DNS and every
`instance`-keyed Prometheus series stay continuous; only `node`-labelled series break.

**Target layout — `/var` on the SATA disk, the whole NVMe to miroir:**

- EPHEMERAL ≈200GB on the SanDisks, ≈90GB on the KINGSTON. **The 50 GiB `/var` cap that bit
  three times simply disappears**, and on the CP etcd stops competing with storage I/O
- The entire 1TB NVMe becomes a miroir `lvmthin` pool — its production backend, no loopfile
  and no reflink requirement (the upstream example points `device` at a partition label, so
  either whole-disk or partition works)
- `kube-nuc` and `kube-hp` keep a small `local` pool. Its real job is **topology membership**:
  proven 2026-08-13, a pod on a node outside the topology is refused with
  `cannot be consumed remotely … the node is not in the storage topology`
- `miroir-replicated` at **replicas 3**, one per M720q — this restores the 3× durability Ceph
  had, which phase 2 flagged as a downgrade, and costs nothing at 45 GiB on 3 TB raw
- ⚠️ The Crucial P3 is QLC; at replicas 3 every write lands on all three, so it gates write
  latency. Worth benchmarking early — this is also the **performance test phase 2 could not
  do**, since a loopfile on shared XFS proves nothing about real disks

#### Gates — all must pass before anything is destroyed

- [ ] **G1 — phase 2.5 complete**, at its stated exit condition
- [ ] **G2 — a barman restore, rehearsed again, against garage.** The one path kopiur cannot
      cover. It has been tested before; test it again close to the date, because Authelia,
      paperless, atuin and immich metadata all live in CNPG. Phase 2.7 moves the backend to
      garage precisely so this gate is earned against a target that has not just silently failed
      for two days — if 2.7 has not cut over by then, this gate is against MinIO and the
      2026-08-19 incident says that is worth distrusting
- [ ] **G3 — keep VolSync's old repository** as a cold second copy on elizabeth. Delete it only
      after phase 3 succeeds
- [ ] **G4 — let it recover unassisted, and treat every intervention as a bug.** No suspending
      Kustomizations and no hand-ordered restore. The cluster is already built to self-recover:
      both CNPG clusters use `bootstrap: recovery` with `externalClusters: source`, so a fresh
      cluster restores from barman rather than running `initdb`, and `components/kopiur` ships a
      populator that refills each PVC from its own last snapshot. Orchestrating by hand would
      hide exactly the defect this rehearsal exists to find. **Write down everything that
      needed hand-holding and fix it in git**, so the next recovery is unattended

Three things to watch rather than orchestrate:

- ⚠️ `onMissingSnapshot: Continue` means a PVC with **no** snapshot comes up empty *and
  healthy-looking*. There is no error to catch — which is the whole reason phase 2.5's exit
  condition is "every PVC protected or explicitly disposable"
- `bootstrap: recovery` makes Postgres **depend on elizabeth being reachable at bootstrap**. If
  the NAS is down or mid-parity, CNPG cannot bootstrap at all
- The first reconcile is a thundering herd: every HelmRelease and image pull at once. Harmless,
  and a useful stress test of the new `/var` sizing

Not gates, but known before the day:

- The **sops age key and BWS token** are exercised by the bootstrap itself, so the phase tests
  them rather than needing them pre-verified.

  ✅ **Resolved 2026-08-16 — and the earlier "only copy on an unbacked laptop" claim here was
  simply wrong.** A second copy was already in BWS as `age-key`
  (`c26e9d84-2735-4317-9564-b3df011ffd26`). Verified: it derives the same public key as
  `./age.key` and as the recipient in `.sops.yaml`
  (`age175fpp0mqvuhmfddz9f5gcvxaxv9x70mgrd0nfcnl2ypq2whckcsqtjds5v`), and sops decrypts with it.

  `just setup` fetches it into `./age.key` on a fresh clone, and refuses to overwrite an
  existing one. BWS stores the bare `AGE-SECRET-KEY-…` line, so the file it writes is 75 bytes
  against the local 189 — age-keygen's two comment lines are the only difference, and the
  secret line is identical.

  **The circularity argument in the old note applied to the wrong direction.** It is real for
  the *cluster*, which reaches BWS only via the sops-encrypted `bitwarden-access-token`. It
  does not apply to a *workstation*, which authenticates with its own `BWS_ACCESS_TOKEN` from
  `.env`. The recovery path therefore does not depend on this laptop: log in to the Bitwarden
  web vault, mint a fresh access token, run `just setup`.

  The key still decrypts four files — `cluster-secrets`, **`bitwarden-access-token`**,
  cert-manager's and flux-instance's — so it remains the thing to guard; it just is not
  single-copy.
- `talosctl kubeconfig` mints a cert-based `admin@kubernetes` from the cluster CA, so admin
  access never depends on Authelia. The narrow footnote: kube-apiserver carries
  `--oidc-issuer-url` for `https://${AUTH_DOMAIN}`, which is unreachable on a fresh cluster.
  It should only log warnings, but the escape hatch is to **comment the OIDC flags out of
  `cluster.yaml` for the bootstrap and add them back once Authelia is up**
- Every restore streams from elizabeth over NFS, and **phase 1.5 is still unexplained**. The
  recovery path runs through the least trusted component — accepted knowingly, not overlooked

#### Execution

- [ ] Freeze: suspend Flux, scale apps to zero, take final kopiur snapshots and a CNPG backup
- [ ] Record the node → IP → disk map and the schematic ID before wiping anything
- [ ] Rename and re-lay-out in git: `talconfig.yaml` hostnames, the three
      `patches/nodes/kube-ceph-0*-ethernet.yaml` files, three control planes, EPHEMERAL sizing,
      miroir pools and classes. Also outside the cluster: `infra/data/networks.yaml` and
      `services.yaml` carry the OPNsense DHCP/DNS entries, and
      `docker/donkey/power-nap-over/config.yaml` references the nodes
- [ ] Delete the `rook-ceph` app tree and the `openebs-hostpath` PVCs it no longer needs
- [ ] `talosctl reset` all five, wiping disks
- [ ] Bootstrap: apply config, `talosctl bootstrap` one CP, wait for **etcd at 3 members**
- [ ] Point Flux at the repo and **let it reconcile unassisted** — miroir pools come up, the
      kopiur populator refills each PVC, CNPG recovers from barman. Watch, do not orchestrate;
      log every intervention as a bug to fix in git
- [ ] Verify: Ceph gone, `/var` sized right, `drbd` on all five, replicas 3, no PVC silently
      empty, alerts clean
- [ ] Benchmark the NVMe pools and **record the numbers phase 2 could not measure**

#### When

Gated, not scheduled: after G1–G4. Budget **half a day**, not two hours — ~45 PVCs plus
verification. Never on the **1st of the month**, when elizabeth's parity check runs
(`0 5 1 * *`). Household services all go dark for the duration — Home Assistant automations,
frigate, the baby monitor, jellyfin — so it needs buy-in, not just a quiet morning.

### Phase 4 — `just merge` and the gpu component

- [ ] Add the `just merge <digest|patch|minor|major>` recipe: bulk-merge Renovate PRs by
      label, skipping the ones labelled `hold`
- [ ] Factor the `ResourceClaimTemplate` of frigate and jellyfin into a `components/gpu`.
      **This is not a new capability**: DRA (`resource.k8s.io/v1`) is already in use in both
      apps. The gain is removing the duplication
- [ ] While factoring, check whether `adminAccess: true` and `allocationMode: All` are
      needed — neither is set today

### Phase 5 — the missing observability

Hardware already in the house, metrics absent.

- [ ] `kromgo` — PromQL-driven badges on `envoy-external`, with the badges in the README.
      The domain is not treated as a secret: manifests still use `${DOMAIN}`, but for a
      single source in `cluster-secrets`, not for confidentiality
- [ ] **Ceph mgr module crashes hold `HEALTH_WARN` permanently — consider v20.2.4.** The
      v20.2.3 pin did its job: mgr memory is stable at **427Mi** with no restarts, where it
      used to grow until OOM. But the `rook` mgr module raises `NotImplementedError` in
      `node_proxy_fullreport` **4 times a minute** — ~5,700 crash reports a day — which keeps
      the cluster in `HEALTH_WARN` and so masks real problems. **Not** a regression: the same
      crash goes back to 2026-05-11. `ceph crash archive-all` clears it until it
      re-accumulates. v20.2.4 exists and is a one-line change to the `cephImage.tag` pin.
- [ ] `snmp-exporter` — HPE OfficeConnect 1820 switch and the UPS, invisible today
- [ ] `drm-exporter` — Intel GPU utilisation, invisible today even though frigate and
      jellyfin transcode on it
- [ ] Evaluate NUT **in cluster**: today the server runs on donkey under Docker and only
      the exporter runs in the cluster
- [ ] Pick up the MinIO metrics scrape from elizabeth (see Follow-ups): it is the same gap,
      and it is what forced the CNPG failures to be diagnosed by hand-querying VictoriaLogs
- [x] **Alert on node disk headroom — done 2026-08-12**, and the root cause was fixed rather
      than just alerted on. `NodeVarSpaceLow` warns at 20% free on `/var`, ahead of kubelet's
      15% eviction line; the built-in `KubeNodePressure` only fires once `DiskPressure` is
      already set, i.e. after pods start dying. Paired with
      `terminated-pod-gc-threshold: "30"`, since the real consumer was never images: dead pods
      pin containerd snapshots that image GC cannot reclaim. Full write-up under phase 2.

### Phase 6 — \*arr stack

Torrent only, no usenet. `tqm` already runs as an hourly cronjob.

- [ ] `qui` (`ghcr.io/autobrr/qui`) — alternative WebUI for qbittorrent. Note: the built-in
      WebUI is the one currently protected by OIDC, so the protection has to move
- [ ] `autobrr` — tracker IRC announces and RSS → automatic grabs into qbittorrent. It is
      the piece that adds the most value on the torrent side
- [ ] `recyclarr` — syncs TRaSH quality profiles and custom formats into radarr and sonarr
      via CronJob
- [ ] `bazarr` — subtitles, integrated with radarr/sonarr and jellyfin
- [ ] Replace the `xseed.sh` script with the `cross-seed` app
      (`ghcr.io/cross-seed/cross-seed`): more capable, and maintained by someone else

## MCP in cluster

MCP servers should be **deployed in the cluster and exposed on `envoy-internal`**, so they
are usable from Claude Code on this machine, from other machines on the LAN, and from the
LLM apps in the cluster. Not as local `uvx` processes.

Today `.mcp.json` points at `uvx mcp-proxy` against Home Assistant's `/api/mcp` endpoint.
The file is correctly in `.gitignore` — it holds a long-lived HA token — and must stay
there.

### Decisions to make before deploying

- [ ] **How to authenticate the MCP endpoints.** An unauthenticated Home Assistant MCP on
      the LAN is a remote control for the house. OIDC is not usable: MCP clients are not
      browsers and do not follow redirects. The verified path is Envoy Gateway's
      `SecurityPolicy.apiKeyAuth`, which extracts the key from a header:

      ```yaml
      apiKeyAuth:
        credentialRefs:
          - {group: "", kind: Secret, name: mcp-apikeys}
        extractFrom:
          - headers: [x-api-key]
      ```

      Verified detail: when extracting from `Authorization`, the value in the Secret must
      **not** include the `Bearer` prefix, because Envoy compares the string as-is
- [ ] **Which mechanism to deploy them with.** Two options: ordinary app-template
      HelmReleases with an HTTPRoute, or `litellm-operator` with `LiteLLMMCPServer`
      resources (`litellm.home-operations.com/v1alpha1`). The second registers them
      automatically as tools inside LiteLLM, which is already deployed here — so they
      become available to open-webui too, not just to Claude Code
- [ ] Decide whether to create a dedicated `ai/` namespace

### Servers to deploy

- [ ] **ha-mcp** (`ghcr.io/homeassistant-ai/ha-mcp`) — dedicated server with a richer tool
      surface than Home Assistant's built-in `/api/mcp`; replaces the current `mcp-proxy`
      bridge. This is the priority. The server's own authentication is undocumented, so it
      must be protected at the gateway
- [ ] **Grafana MCP** (`grafana/mcp-grafana`) — queries against Prometheus, Loki,
      dashboards and alerts; needs `GRAFANA_URL` and `GRAFANA_SERVICE_ACCOUNT_TOKEN`. It
      answers a pain already recorded below: the weekly CNPG failures were diagnosed by
      hand-querying VictoriaLogs

### To explore

Unverified candidates. Each item should be closed with "exists and is useful" or "does not
exist", not left open.

- [ ] **kubesearch** — check whether an MCP server for kubesearch.dev exists; it would give
      access to community deployment patterns while adding new apps
- [ ] **context7** — up-to-date library documentation. Evaluate whether it helps in a repo
      that is almost entirely YAML
- [ ] **Kubernetes** — worth it only if it offers something `kubectl` through a shell does
      not already give
- [ ] **Paperless / Immich / Karakeep / Jellyfin** — self-hosted apps present here that may
      have an official or community MCP. Verify one by one: an MCP over paperless would make
      documents queryable, which is close to the "catalog documents with AI" TODO item
- [ ] **CNPG / Postgres** — querying the cluster databases. Weigh carefully: it would give
      an agent read access to all application data

## TODO

- [ ] Investigate the issue caused by exposing both external and internal gateways simultaneously — appears to cause problems in Chrome (e.g., mixed routing, cookie conflicts, or certificate mismatches between the two gateways)

- [ ] Improve Home Assistant dashboard
- [ ] Add Syncthing
- [ ] Find a way to use AI to automatically catalog documents in Paperless-ngx
- [ ] Review and merge `mise-upgrade-dependencies` branch (mise upgrades + Romm removal)

## Follow-ups

- [ ] NFS canary reliability — Unraid disrupts NFS connections when the mover runs, canary doesn't handle it well
- [ ] Scrape MinIO metrics from elizabeth into Prometheus — currently zero MinIO metrics exist, so restarts, latency and S3 error rates are invisible from the cluster. This is what forced the weekly CNPG backup failures to be diagnosed by hand-querying VictoriaLogs for `IncompleteBody` instead of a single query
- [ ] Enable syslog mirroring on elizabeth **to a share, not to flash** — the 5 parity sync errors of 2026-08-02 could not be investigated per-sector because syslog had already rotated and nothing is persisted. Without this, the next array incident is equally unexplainable
- [ ] Plan replacement of the parity disk `sdf` (WD100EFAX) — 57,077 power-on hours (~6.5 years), 1 ATA error logged, recorded max temp 60 °C. SMART still PASSED and it was not implicated in the sync errors, but it is by far the oldest device in the array (the two data disks are at 12,009h)
