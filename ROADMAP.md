# Homelab Roadmap

## Roadmap

Phases in order. Each gets an execution plan under `docs/superpowers/plans/` **when you
reach it**, not before: that way every plan is written against the real state of the repo
rather than the state predicted weeks earlier.

The half-numbered phases were inserted as work revealed them — 1.5 by a recurring failure,
2.5 because a 19-app migration should not be planned before a single volume has been
restored, 2.6 by a node that hung unreachable and had to be power-cycled by hand, and 2.7 by
the one backup kopiur cannot cover silently failing for two days on the least reliable host.

## 🔴 Urgent — outside the phase order

Live faults. They belong to no phase because they should not wait for one; both were found on
2026-08-24 while auditing the phase 3 renames, not by any alert.

- [x] ✅ **navi's doco-cd token — fixed 2026-08-24.** The cause was not a revoked token: navi's
      `.env` had **`BWS_ACCESS_TOKEN=` with an empty value**, so doco-cd authenticated with an
      empty credential and BWS answered `invalid_client` (RestartCount had reached **6416**,
      ~4.5 days). `infra/scripts/bootstrap-navi.sh:53` passes `--bws-token ${BWS_ACCESS_TOKEN}`
      and `bootstrap.sh` falls back to the existing value rather than failing, so a bootstrap run
      with that variable unset writes an empty token **and reports success**.
      Fixed with a dedicated access token on the shared `doco-cd` machine account. navi
      immediately polled and **force-recreated the `matchbox` stack** — closing 4.5 days of drift
      on the PXE server. Verified after: `matchbox` serving `boot.ipxe` and the kernel asset at
      HTTP 200, reachable from donkey.
- [x] ✅ **elizabeth was running on the operator's personal token** — found while fixing navi
      (same SHA as the workstation `.env`). Given its own token on the same machine account, so
      rotating the operator credential can no longer silently kill a host's GitOps. Each host now
      holds a distinct token and the operator token is on none of them.
- [ ] **Make `bootstrap.sh` refuse an empty `BWS_ACCESS_TOKEN`.** This is the defect that cost
      4.5 days: it accepted an empty value, wrote it, and exited 0. A guard that fails loudly
      turns a silent multi-day outage into an obvious bootstrap error
- [ ] **Watch charmander's 100 Mbit link — hardware.** `eno1` negotiates **100Mbit/Full** while
      the other four nodes are at `1000Mbit`. Nothing in `patches/` forces a speed and the link is
      clean (zero errs, drops, carrier events), so it is **cabling or the switch port**, not the
      `e1000e` driver. It matters because charmander is a **control plane running etcd** and hosts
      a miroir loopfile pool, and replicated writes are already network-bound at 1 GbE — this node
      is at a tenth of that. It may also explain why iPXE's native driver could not bring the link
      up during the rebuild. Reseat or replace the cable, try another port, then re-check with
      `talosctl -n 10.1.10.11 get links eno1`

      🔥 **No longer theoretical — it flapped and took out storage on 2026-08-24.** The link
      dropped for ~21 seconds and every warning alert in the cluster followed from it:

      ```
      05:55:34  e1000e eno1: NIC Link is Down
      05:55:44  talos removed address 10.1.10.11/24, deleted the default route
      05:55:52  EXT4-fs error (drbd1020): aborted journal -> Remounting filesystem read-only
      05:55:55  e1000e eno1: NIC Link is Up 100 Mbps Full Duplex
      05:56:00  address + route restored
      ```

      DRBD lost quorum on several volumes (`quorum( yes -> no )`), writes failed, and ext4
      aborted its journal. **Only charmander was affected** — the other four nodes logged zero
      read-only or aborted-journal events, which is what isolates this to the link rather than to
      miroir or the network as a whole.

      **The lasting damage is the part worth knowing: a filesystem that goes read-only stays
      read-only after the link returns.** DRBD recovered by itself 14 seconds later, but
      `victoria-logs` kept crash-looping for ~12 hours (152 restarts) on
      `cannot create lock file … read-only file system`, and all five `fluent-bit` pods sat at
      `0/1` because their sink was gone — so **log ingestion was dead cluster-wide and nothing
      said so beyond the generic pod alerts**. Recovery needed a manual `kubectl delete pod`; the
      CSI driver then ran `fsck.ext4` on reattach and remounted r/w cleanly.

      This is the first real exercise of `quorum: freeze`. It did its job — froze rather than
      allowing divergence — but **freeze protects the data and not the availability, and nothing
      automatically remounts afterwards.** Worth considering a recovery path for it.

      **Mitigated 2026-08-25: charmander is drained and cordoned**, running the cluster on four
      nodes until the cable is sorted. Four nodes carry it comfortably — 25.8 cores and ~67 GiB
      allocatable against ~9.5 cores and ~28 GiB of total requests. The drain is the *correct*
      mitigation, not just convenience: the read-only damage hits volumes whose **pods** sit on
      charmander, whereas a volume that merely holds a *replica* there keeps quorum (2 of 3) when
      it drops. `miroir-agent` is a DaemonSet and survives the drain, so storage redundancy is
      unchanged and an empty charmander makes the next flap harmless.

      **`autoDiskfulAfter: 30m` set 2026-08-25.** Cordoning charmander did not move its data:
      **8 of 11** affected volumes still had one of their two diskful copies stranded there,
      leaving one reachable copy across four schedulable nodes, so most pods landed on a diskless
      leg. That costs more than the benchmark suggested — a pod with a local leg gets free reads,
      a diskless one pays network for reads *and* writes. Conversions ran within ~3 minutes of the
      controller restarting (the legs were long past the threshold) and the 11
      `MiroirVolumeRemoteConsumer` alerts went to 0; **10 volumes are now 3-diskful** and
      bulbasaur's pool went 20 → 73 GiB. That is more than the 35 GiB the volume sizes sum to —
      the full-sync appears to allocate the whole device rather than staying thin, worth
      remembering when budgeting the next conversion. Still only 28% of a 263 GiB pool.

      ⚠️ **These extra replicas do not go away when charmander returns** — upstream is explicit
      that "evicting a replica is an operator decision". Once the cable is fixed, decide whether
      to keep 3-diskful or trim back by hand. 30m rather than upstream's 10m example because
      KEDA's nfs-stale scaler recreates pods on a ~5-minute cycle, and a threshold near that would
      convert legs for pods about to move. `autoEvictAfter` deliberately left unset: charmander is
      cordoned but healthy, and its replicas should stay.

      Two things that surfaced doing it, worth knowing before the next drain:
      - `cluster18-1` sat on **`miroir-local` PVs pinned to charmander** and could not be
        rescheduled. Rebuilt with `kubectl cnpg destroy cluster18 1`; CNPG re-cloned it onto
        squirtle in under 30s (283 MB). Any node-local CNPG instance has this property — check
        before draining.
      - **`tuppr` tolerates `node.kubernetes.io/unschedulable`**, so it rescheduled straight back
        onto the cordoned node. Harmless, but cordon does not keep it off.

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

### Phase 1.5 — NFS stale handles — ✅ done 2026-08-22

Detection and automatic recovery are live. The **root cause is still unidentified** and is
not preventable from the cluster side, which is precisely why the answer is detect + recover
rather than fix.

**What ships:** [`adumat/nfs-stale-exporter`](https://github.com/adumat/nfs-stale-exporter) —
a standalone public Go project (scratch image, 13.6 MB) with its own Helm chart, both on GHCR.
A DaemonSet in `observability` statfs's every kubelet NFS **volume root** and exports per-pod
metrics. It holds no RBAC and never contacts the API; identity is resolved in Prometheus and
recovery is done by the existing KEDA `nfs-scaler`.

```
nfs_mount_stale{pod_uid}  ->  kube_pod_info (uid)  ->  kube_pod_labels
  ->  nfs:mount_stale:app  ->  min_over_time(...[5m])  ->  ScaledObject scales 0 -> 1
```

Alerts: `NfsMountStale` (2m, expected to self-resolve once the pod is bounced),
`NfsMountStaleUnrecovered` (20m, the one that pages), `NfsExporterSeesNoMounts`,
`NfsScalerCoverageGap`.

**Coverage closed.** The roadmap previously said "nine apps mount NFS inline". That undercounted:
there are **two** classes — inline `type: nfs` **and** NFS-backed static PVs — totalling 14
consumers, of which only 9 had a ScaledObject. The 2026-08-21 incident hit metube and pyload-ng,
both in the uncovered PV class. All 14 are now covered, and `NfsScalerCoverageGap` makes a new
uncovered consumer loud instead of silent.

**Verified end-to-end 2026-08-22** on a throwaway export: forcing ESTALE via an `fsid` change
flipped the metric to `1 reason="stale file handle"` while the pod stayed `1/1 Running` with no
kubelet event; the alert fired; deleting the pod resolved it. The coverage alert was proven with
a deliberately-true control (14 vs 0), since an empty `unless on(...)` looks identical to full
coverage.

**Two hypotheses refuted, so they are not retried:**

- **`fuse_remember` / idle-forgetting.** elizabeth runs `shfs -o remember=330` and Unraid's own
  help text advertises the tunable as the cure. It is not the mechanism: after `drop_caches`
  evicted 837k dentries, shfs RSS fell 124.7 → 69.4 MB — proving the timer fired and freed
  nodeids en masse — yet the exported mount stayed healthy, root and child. `exportfs` pins the
  export root in the kernel export table where `drop_caches` cannot reach it. It is also read
  only at **array start**, so changing it needs a stop/start, which invalidates every handle anyway.
- **The mover.** It changes which disk backs a *file*; it never touches the export root.

Leading remaining candidates: shfs restart after an unclean shutdown, or Unraid regenerating
`/etc/exports` on a share or array event.

**Still open:**

- [x] **Observed a real stale mount 2026-08-25 — and the exporter MISSED it.** 🔴 The rehearsal
      used a synthetic export; the genuine article finally appeared on `kapowarr`, whose pod
      failed 2,210 times over 8h with
      `stat /var/lib/kubelet/pods/aded7795-…/volumes/kubernetes.io~nfs/media: stale file handle`.

      **The exporter discovered that exact mount, probed it, and reported `nfs_mount_stale = 0`.**
      Proven side by side on squirtle:

      ```
      lstat  <path>   -> stale file handle
      statfs <path>   -> success            <- what the exporter calls
      ```

      **Root cause: `internal/probe/probe.go` uses `unix.Statfs`.** `statfs()` returns
      filesystem-level information and can be answered from cached superblock data without
      resolving a file handle, so it cannot see ESTALE. The design intent was always "stat the
      **root**" — it was implemented with the one syscall that does not do that. So the detector
      has been reporting healthy for the precise failure it exists to catch since 2026-08-22, and
      the KEDA scaler gated on it never fired.

- [x] **Fixed and released as v0.1.1, deployed 2026-08-25.** `probe.go` now calls `unix.Lstat`;
      `probe.Statfs` renamed to `probe.Stat`. `lstat` rather than `stat` so a mount root replaced
      by a symlink fails instead of silently following the link off the mount. Timeout and
      `inflight` guard unchanged. `TestStatUsesLstatNotStatfsOrStat` pins the syscall via a
      dangling symlink — `lstat` succeeds on one, `stat` and `statfs` both return ENOENT — and the
      guard was verified to fail when the syscall is reverted.

#### What the fix immediately revealed: this was never rare

Within minutes of rolling out v0.1.1 the exporter flagged **11 of 21 mounts stale** — jellyfin,
komga, immich-server, filebrowser, qbittorrent, radarr, sonarr, metube, mylar3, pyload-ng,
kapowarr. Confirmed independently with `talosctl list` (an lstat) on each pod's own node, so not
an artefact: every one returned `stale file handle`. All eleven pods were `Running` and `ready` on
dead filesystems.

**The old probe reported zero, which made the problem look occasional. It is closer to half the
mounts, continuously.** One kapowarr pod was only **25 minutes old** and already stale, so mounts
re-stale quickly — the root cause remains the unexplained Unraid/fuse behaviour, and detection
still is not prevention.

#### The KEDA self-heal loop fired for the first time, and it works

The scaler had never once fired, because the metric it reads was always 0. Its first real
exercise, unassisted end to end:

```
t+90s   11 apps scaled 1 -> 0   (min_over_time(...[5m]) == 1 satisfied)
t+405s  scaled 0 -> 1           (pod gone -> mount gone -> metric cleared -> fresh mount)
t+495s  filebrowser -> 0 again  (its new mount went stale within ~90s)
t+720s  filebrowser -> 1        settled
```

Final state: 17 mounts discovered, **0 stale**, every app back at 1/1, no manual intervention.
Scaling to zero removes the pod and therefore the stale mount, which clears the metric and lets it
scale back up onto a fresh one — the recovery is a side effect of the protection, and it holds.

Two things this exposes, worth their own thought rather than being buried here:
- **A flapping app is now possible.** filebrowser cycled twice because its replacement mount went
  stale almost immediately. If re-staling ever outpaces the 5-minute window an app could sit in a
  scale loop, which is noisier than being down.
- **The apps were silently broken before today.** Nothing alerted for however long those eleven
  had been stale, because the detector said healthy. The alert history starts now.
- [x] **`nfs-canary` retired 2026-08-22.** It was segfaulting (exit 139, 41 restarts in 22h — a
      use-after-free: the timeout path destroys the libnfs context while the orphaned probe
      thread is still inside it), watched a retired export, and probed from a single replica.
      Its server-reachability job is now `nfs_server_reachable` from the exporter on all 5
      nodes. Its fresh-session probe is gone with it; that only detected the Unraid
      version-drop case, which is not actionable by a scaler and shows up as pod mount
      failures anyway.
- [ ] The exporter re-probes nothing that is already blocked, but a genuinely *hung* mount still
      pins one OS thread until the kernel gives up. Bounded here by `soft,timeo=50,retrans=3`.

The recognition and manual recovery procedure stays in [AGENTS.md](AGENTS.md), traps section —
`kubectl delete pod` remains the fix when recovery has to be done by hand.

### Phase 2 — storage validation: prove kopiur and miroir, migrate nothing — ✅ done

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

**Risk:** backups run over NFS to elizabeth, whose stale handles are now detected and
auto-recovered (phase 1.5) but whose root cause is still unidentified. Dual-running roughly doubles backup I/O to it, which is why the existing
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
- [x] ~~**Blocked until elizabeth's parity check finishes**~~ — cleared 2026-08-20. The check
      (started 2026-08-18 after the unclean shutdown) finished at 01:27 UTC on 2026-08-20 having
      corrected **145 sync errors**, and the migration proceeded that day.
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
- [x] **Batch 2 done 2026-08-20: pyload-ng, radarr, sonarr, then qbittorrent.** The
      `ssa: IfNotPresent` label proved out exactly as intended — an app whose git manifest had
      moved to `components/kopiur` kept running on its old PVC, Kustomization Ready, a stable
      resting point rather than a half-migration.

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
- [x] **All 18 apps migrated to kopiur — complete 2026-08-20.** Every one verified by diffing a
      per-file checksum manifest of the quiesced volume against the restored one before the app
      was allowed to start. In batches, never in bulk.
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
- [x] **Leftover snapshots cleaned up 2026-08-21.** The two `premigrate` copies
      (`downloads/qbittorrent`, `home/home-assistant`) came from runs that aborted before their
      cleanup step — quiesced safety copies taken with the app stopped, just before its PVC was
      deleted and recreated, which is what the restore then pulled from. Both apps have since
      taken successful **scheduled** backups on two consecutive days, so the copies were
      redundant and are deleted.

      `media/romm-fixcheck2` deleted too, because the condition set for it is now met — and it
      confirms the romm fix on a real scheduled run rather than only a manual test:

      | snapshot | result | mover |
      | --- | --- | --- |
      | `romm-20260819004135` | Failed | root (uid 0) |
      | `romm-20260820004052` | Failed | root (uid 0) |
      | `romm-20260821004055` | **Succeeded** | uid 1000 |

      Two consecutive scheduled failures under the root mover, then success once it went back to
      1000. That closes the loop opened when the "fix" was found to be backwards.

      Still there:
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

      🔴 **This is phase 3's G1 blocker, and it is subtler than it looks.** None of these four
      set `dataSourceRef`, so a rebuilt cluster brings them up **empty and reporting healthy** —
      which G4 counts as a bug. `just backup-audit` reports "clean" because it verifies backups
      *exist*, not that they would be *restored*.

      `dataSourceRef` is **immutable**, so it cannot be added to a PVC that already exists. Each
      of the four needs a different mechanism, and three of them carry a real hazard:

      | PVC | owner | how | hazard |
      | --- | --- | --- | --- |
      | `database/mosquitto` | Flux (`pvc.yaml`) | ✅ **done** — `dataSourceRef` + `ssa: IfNotPresent` | none; no-op now, correct on rebuild |
      | `database/pgadmin` | Helm (app-template) | ✅ **done** — PVC recreated, restored from snapshot | — |
      | `services/paperless-ai` | Helm (app-template) | ✅ **done** — PVC recreated, restored from snapshot | — |
      | `observability/grafana-pvc` | grafana-operator | ✅ **done** — PVC recreated via `replicas: 0`, restored from snapshot | needed two attempts; see below |

      **Three of four closed 2026-08-21.** For the two Helm-managed ones the immutability problem
      dissolved once the PVC could be recreated: with the HelmRelease **suspended** (so Helm cannot
      recreate the PVC without the field mid-way), take a quiesced snapshot, delete the PVC,
      resume — Helm recreates it with `dataSourceRef` and the Restore populates it. Both came back
      byte-identical on the files that matter: pgadmin's `pgadmin4.db`, and paperless-ai's
      wizard-generated `.env`. The only diffs were transient (pgadmin's empty session files,
      paperless-ai's `chromadb` index being written by the running app). So this also **proved the
      restore path** for these PVCs, not just declared it.

      ✅ **G1 is closed — all four done 2026-08-21.** grafana took two attempts, and the failed
      one is worth keeping because the obvious approach is the wrong one.

      Adding `dataSourceRef` to the CR while leaving the live PVC alone was tried first, on the
      theory that the operator would tolerate the mismatch. It does not:

      ```
      failed to reconcile Grafana stage: PersistentVolumeClaim "grafana-pvc" is invalid:
        spec: Forbidden: spec is immutable after creation except resources.requests
      ```

      The operator entered a reconcile error loop, so the change was reverted (the error went to 0
      within minutes). An operator that cannot complete reconciliation is worse than the gap it
      was closing, since no later grafana change would apply either.

      The working sequence, and **the ordering is the whole trick**:

      1. `spec.deployment.spec.replicas: 0` in the CR — the operator must stop grafana itself.
         Scaling the Deployment by hand is reverted (it is owned by the CR), and deleting a
         still-mounted PVC arms the delete behind the `pvc-protection` finalizer to fire later —
         the failure that cost radarr 7 hours
      2. quiesced snapshot while it is stopped (49.5 MB)
      3. **add `dataSourceRef` to the CR *before* deleting the PVC.** Deleting first does not
         work: the operator recreated the PVC within **6 seconds**, without the field, and the
         window is far too short to win
      4. delete the PVC — the operator recreates it with `dataSourceRef` and the Restore populates
         it
      5. remove `replicas: 0` and let it start on the restored volume

      Result: 48.9 MB restored against a 49.0 MB baseline, `grafana.db` and plugins intact,
      operator immutability errors back to 0. Lowest-stakes of the four in any case — the
      dashboards are `GrafanaDashboard` CRs and survive regardless, and 47.5 MB of the 49 MB is
      re-downloadable plugins.

- [ ] ⚠️ **Unrelated, found while doing the above: grafana-operator cannot authenticate to
      Grafana.** `failed to reconcile Grafana stage: failed to authenticate with instance` —
      **84 occurrences in 7 hours**, first seen at 17:50 UTC, i.e. before and independent of the
      `dataSourceRef` attempt. Worth chasing because the operator authenticates to Grafana's API
      to push `GrafanaDashboard` CRs: while it cannot, dashboard changes in git are **not**
      reaching Grafana, silently. Note the config sets `auth.basic.enabled: 'false'`, which is a
      plausible starting point.

      ⚠️ **For the two Helm-managed ones, do NOT simply switch to `existingClaim`.** Neither PVC
      carries `helm.sh/resource-policy: keep`, so removing it from the release makes **Helm delete
      the volume** — the same class of mistake that cost radarr 7 hours. The safe order is:

      1. add `retain: true` to the persistence item (app-template then stamps
         `helm.sh/resource-policy: keep`) and let it apply
      2. only then switch to `existingClaim` and add `components/kopiur`, whose PVC carries
         `ssa: IfNotPresent` so it leaves the live volume alone
      3. verify the PVC survived and is still `Bound` before touching the next one
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
      content self-expires at retention (14d then, **21d since 2026-08-21**), so a restore would
      recover metrics already partly stale; victoria-logs is the same argument (**30d** since
      2026-08-21 — and its retention had never actually been applied before then, see phase 2.6).
      Longer retention slightly strengthens the case *for* backing these up, but not enough to
      change the decision: the data is still self-expiring and still dwarfs the repository. alertmanager is only 40 KB, but its one
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
- [x] Keep the old repository as a cold fallback **through phase 3**, then delete it.
      **2026-08-24: the ClusterRepository is removed; the data on elizabeth is kept for now.**
      Active: the `volsync-repo` ClusterRepository and the data on elizabeth are both kept, and
      the `kopia` UI reads them. Its `KopiaMaintenance` went away with the operator, which is
      fine for a read-only archive — maintenance compacts indexes, it is not needed to read
- [x] **Deleted — confirmed 2026-08-24.** The leftover pre-migration rescue PVCs, `prowlarr-rescue`
      included, are gone; no `*-rescue` PVC remains in any namespace. They did not survive the
      phase 3 rebuild, which only restored PVCs that had snapshots
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
- [x] ✅ **RESOLVED — MinIO on elizabeth was flapping, and it is why immich-db had no base backup
      from 2026-08-18 to 2026-08-20.** Fixed in two stages: a MinIO restart brought the drive back
      online and produced `backup-20260820192847` (the first base backup in two days), and phase
      2.7 then moved both clusters off MinIO to garage entirely, so the failure mode is retired
      rather than merely cleared. Diagnosis kept below because the reasoning is reusable — it was
      not a CNPG problem and not immich-specific:

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

### Phase 2.6 — node self-recovery: hardware watchdog and kernel logs — ✅ done 2026-08-21

*Inserted 2026-08-18 by a node that hung unreachable and had to be power-cycled by hand.*
**Re-verified 2026-08-23 after the phase 3 rebuild**, since every node was wiped: the watchdog
is armed on all five (`timeout=5m0s`, `feedInterval=1m40s`, squirtle included as a new control
plane), `panic=10` is on the kernel cmdline, and fluent-bit is Running on all five. The
controls are in git, so the rebuild restored them without intervention.

The one unchecked box below is deliberate — it moved to phase 5 and to §8.1 of the
blackout-monitor design, because it only works from a host that does not share the cluster's
fate.

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

- [x] **Enable the Talos hardware watchdog — done 2026-08-21.** `WatchdogTimerConfig` against
      `/dev/watchdog0`, `timeout: 5m`, via
      [machine-watchdog.yaml](kubernetes/talos/patches/global/machine-watchdog.yaml). Applied to all
      five nodes with `apply-config`, no reboot. Verified by read-back:
      `/sys/class/watchdog/watchdog0/timeout` = `300` and `state` = `active` on every node, with
      Talos feeding at `feedInterval: 1m40s`. The read-back is the test — the driver reports
      `max_timeout=0` because it advertises no limits, so exit status alone would not prove 300s
      was accepted rather than clamped. Hardware is TCO `Version=6`, ceiling 613s.
      The device exists and nothing arms it. If the kernel stops petting it the board resets
      itself, turning "hangs until someone drives over" into a ~1 min reboot — and it works
      whether the cause is the NIC, the kernel or RAM
- [x] **Add `panic=10` — done 2026-08-21.** In the **schematic's `extraKernelArgs`** in
      [talconfig.yaml](kubernetes/talos/talconfig.yaml) — **not** to `machine-kernel.yaml`, which
      configures kernel *modules*. This is a schematic change, so it needs a new installer image
      and a **rolling `talosctl upgrade`**, one node at a time respecting etcd quorum (only two
      members). Silence `NodeUnexpectedReboot` first or it pages once per node.
      Rolled out workers-first then control planes; schematic went
      `e4e5b0e3…d85044` → `38130295…31559b`. All five verified `panic=10` present and
      `watchdog=300 active` — **the watchdog survives a schematic reinstall**, so Task 2's
      `apply-config` setting does not need re-applying per node.
      ⚠️ Two gates that the written plan got wrong and had to be corrected mid-rollout:
      `kubectl get nodes` showing `Ready` is **not** sufficient between Ceph hosts — the node is
      Ready within seconds while its OSD needs ~2.5 min, and upgrading the next host in that
      window drops Ceph below `min_size 2` and halts cluster I/O. Gate on
      `ceph osd stat` = `3 up` **and** `pg stat` = `81 active+clean`. And between control planes,
      gate on `talosctl etcd status` showing **matching RAFT INDEX/TERM with an empty ERRORS
      column** — "both members are listed" is a weaker check that would let you take the second
      down while the first is still catching up, which loses quorum permanently on a two-member
      cluster.
- [x] **Ship kernel and service logs off-node — done 2026-08-21, verified receiving.** **To the
      local fluent-bit, not straight to VictoriaLogs.** Talos emits `json_lines` only; VictoriaLogs'
      syslog listener accepts RFC3164/RFC5424 only, and Talos drops silently on a destination it
      cannot deliver to, so the direct path looks deployed and ships nothing. Add a `tcp` INPUT
      (`format json`) to fluent-bit on a hostPort and point Talos at `127.0.0.1` — a ClusterIP would
      need Cilium healthy, which a node with broken networking does not have. Was: into
      VictoriaLogs. fluent-bit collects *container* logs only, which is exactly why this
      incident left no kernel evidence. Verify the schema against Talos 1.13 first.
      **Verified end to end**: all five nodes shipping, ~82 k records/30 min, correctly split into
      `node` + `talos-level` stream fields with `_msg`/`_time` mapped. Kernel messages *are*
      included — `talos-service: kernel`, ~3.7 k/30 min — which was the actual requirement, since
      the whole point is that the next hang leaves evidence. Volume order by service:
      `machined` 48 k, `etcd` 8 k, `cri` 7 k, `dns-resolve-cache` 6 k, `controller-runtime` 4 k,
      `kernel` 3.7 k, `kubelet` 3 k.
      ⚠️ **Query trap**: do **not** select these with `node:*`. Container logs carry their own
      `node` field (CNPG's records, for one), so `node:*` silently over-matches application logs
      and you will read a pod log and think it is a kernel log. Select on `talos-service:*`.
      Intake roughly doubled — `machined` at 48 k records per 30 min is by far the biggest new
      contributor and is mostly routine controller chatter. **Checked 2026-08-21: no capacity
      problem, and no PVC change needed.** 3.75 GB in use at **38.6 bytes/row** compressed;
      Talos adds ~7.7 M rows/day (~297 MB/day). Deliberately *not* filtering `machined` out:
      space is not the constraint, and a filter risks discarding the very evidence this task
      exists to keep — query around it with `talos-service:kernel`.
      **Retention raised instead, to spend the headroom on forensic depth — metrics and logs
      both at 30 d** (metrics 14 d → **30 d**, ~37 GB of 52.5 GB = 71 %; logs pinned at **30 d**,
      ~12.7 GB of 21.5 GB = 59 %). **Deliberately matched**: correlating an incident across
      metrics and logs is the point of having both, and the shorter side silently caps how far
      back any comparison can reach. Chosen because the
      fault this phase was built for recurs on a longer cycle than 14 d and a window that cannot
      reach the previous occurrence cannot be compared against it. Prometheus also had
      `retentionSize: 50GB` on a 52.5 GB volume — 95 %, which is a cliff edge rather than a guard
      rail and left nothing for WAL plus compaction — now **40 GB**. VictoriaLogs gained
      `retentionDiskSpaceUsage: 16GiB` as the same kind of backstop.
      ⚠️ **Prometheus parses size suffixes as BASE-2: `40GB` means 40 GiB.** Confirmed via
      `/api/v1/status/runtimeinfo`, which echoes it back as `30d or 40GiB` — the API is the only
      place the parsed unit is visible. Real figures: 42.9 GB decimal = **82 % of the volume**,
      34.5 days of capacity at 1.25 GB/day, a **15 % growth buffer** over the 30 d target, so
      *time* stays the binding constraint instead of size quietly trimming below 30 d. I briefly
      raised this to `43GB` reasoning in decimal units — that is **88 %** of the volume, past the
      ~85 % where the cap stops being a graceful trim and starts risking a full disk. Do not
      re-make that change; if 40 GB ever binds, **grow the PVC** (Ceph has ~2.6 TiB free).
      ⚠️ **The VictoriaLogs retention had never actually been applied.** A top-level
      `retentionPeriod: 14d` sat in the values for 125 days while the chart read
      **`server.retentionPeriod`** and used its own default of `1` — which means one **month**,
      not one day. A wrongly-nested Helm value is **silently dropped**: no error, no warning, and
      `flux reconcile` reports success because the manifest it applied is internally valid. The
      only place the truth appears is the **rendered argument** in the StatefulSet, so that — not
      the values file — is what must be checked after any chart-value change. Setting the
      originally-intended 21 d would have **deleted 9 days of real history** while looking like an
      increase; hence 30 d.
- [x] ~~Export **EDAC** counters, so a single-bit RAM error — which hangs a box in precisely
      this way — stops being invisible~~ — **CLOSED 2026-08-21, not implementable. The hardware
      cannot detect memory errors at all.** This was scoped as "load the missing EDAC module",
      and that premise was wrong: `ie31200_edac` is **already built into the Talos kernel and
      already loaded** on all four Coffee Lake boxes. It probes at every boot and refuses:

      ```
      EDAC ie31200: No ECC support
      ```

      The i5-8400T/8500T are Core i5 desktop parts with non-ECC DIMMs, so the memory controller
      has no ECC logic to report from — `/sys/devices/system/edac/mc` exists but registers no
      `mc0`, and Prometheus holds **zero** `node_edac_*` series. kube-nuc (i5-10210U, Comet
      Lake-U) has no EDAC driver probe whatsoever. The gap is not software: **without ECC memory
      a single-bit error is not detected, it is silently wrong**, so there is nothing any
      exporter could surface. Reopen this only if a node is ever rebuilt on a Xeon E/W or Ryzen
      Pro board with ECC DIMMs, at which point the driver is already present and only the
      alerting rule is needed.

      ⚠️ Consequence worth stating plainly, because it changes what the rest of phase 2.6 is
      worth: **RAM remains the one hang cause with no detection path**, and it fits kube-ceph-03's
      symptoms (alive, powered, NIC dead, no logs) as well as the e1000e theory does. It cannot be
      ruled in or out by monitoring — only by a memtest on a physical visit. The watchdog and
      `panic=10` still *recover* from it blindly, which is why they were the right first move.
- [x] **Alert on `node_network_carrier_changes_total` rising — done 2026-08-21**, as
      `NodeNICCarrierFlapping` in
      [prometheusrule-node-health.yaml](kubernetes/apps/observability/kube-prometheus-stack/app/prometheusrule-node-health.yaml).
      It catches a flapping NIC *before*
      a full hang, and its being flat at 0 is what weakened the e1000e theory here
- [x] **Fix the NUT alert rules — done 2026-08-21.** The UPS had been reporting
      `ups.status: ALARM OL CHRG` with `ups.alarm: "Battery voltage too low!"` at
      `battery.charge: 100` and **nothing alerted**, which is why Unraid warned for months while
      the cluster stayed silent. Rewritten in
      [prometheusrule.yaml](kubernetes/apps/observability/nut-exporter/app/prometheusrule.yaml);
      scrape lowered 60s → 30s in
      [helmrelease.yaml](kubernetes/apps/observability/nut-exporter/app/helmrelease.yaml).

      **Three of the five planned rules turned out to be unimplementable, and the plan's headline
      rule was one of them.** Verified against the exporter's raw `/ups_metrics`, not assumed:
  - [x] **The ALARM condition IS alertable, via `ups.alarm` — done 2026-08-21 as `UpsAlarm`.**
        Not via the status flag: the exporter emits a **fixed 15-flag set**
        (`BOOST BYPASS CAL CHRG DISCHRG FSD HB LB OB OFF OL OVER RB SD TRIM`) and **ALARM is not
        in it**, so `flag="ALARM"` is genuinely impossible. But the `ups.alarm` *variable* works.
        The exporter turns a string into a gauge only if it matches **`--nut.on_regex`**, whose
        default (`^(enable|on|true|active|...)$`) no alarm text matches — which is the real reason
        it was silently absent. Every NUT alarm string ends in `!`
        ("Battery voltage too low!", "Replace battery!") and **no other variable this UPS reports
        contains one**, so `on_regex` now carries a `|!` branch and alarms coax to 1 with no
        collateral. **`--nut.vars_enable=` was never the relevant lever**, and assuming it exported
        "everything" is what made this look impossible.
        Verified by deploying a throwaway `|ECO` branch first, which made
        `outlet.[12].ecocontrol` appear — proving both that the flag is plumbed through the chart
        and that coercion works, neither of which can be exercised on demand because `ups.alarm`
        **only exists while an alarm is active**. Also confirmed Flux's envsubst does not mangle
        the `$` in the anchored pattern. ⚠️ Honest limit: the `!` branch itself stays **unexercised
        until a real alarm**, and the alarm *text* is not in the metric — read it with
        `docker exec nut-server upsc ups@localhost ups.alarm`.
  - [x] ~~`ups.test.result`~~ and ~~`battery.voltage`~~ — **these two really are impossible, but
        not because of the exporter.** A full `upsc` dump shows **neither variable exists on this
        device at all**: `usbhid-ups`/MGE HID does not publish them for the Ellipse ECO 650.
        `battery.voltage` is even in the exporter's *default* `vars_enable` list, so it would be
        exported the moment the UPS offered it. No exporter or flag can conjure them; only
        different hardware would. `output_voltage` is mains output, not the pack, so it is not a
        substitute.
  - [x] `ups.load` and `battery.runtime` **while on line power** — done, and this is the real fix:
        every previous battery rule required `flag="OB"`, so none could warn *before* an outage.
        `UpsRuntimeInsufficientOnLine` / `UpsRuntimeCriticalOnLine` evaluate on line power.
  - [x] `battery.charge` failing to return to full — done as `UpsChargeNotRecovering`.
  - [x] Dropped `for:` on all flag-based rules and raised the scrape to 30s.
  - [x] Also added flags nothing watched: **`FSD`** (upsmon has decided to kill every client —
        the most consequential flag in the set and it was unmonitored), `OFF`, `OVER`, `BYPASS`,
        and `LB` (distinct from `charge < 50`: the UPS raises LB on voltage under load, and can
        assert it at a charge reading well above 50%).

      **Thresholds came from 14 days of measured history, so they do not chatter**, and every
      expression was checked against live Prometheus **with positive controls** — an empty result
      otherwise cannot be distinguished from a broken `and on(...)` join:
  - Runtime on line power floats **265–560 s** per instance → warn at 240 s, critical at 150 s,
    smoothed with `avg_over_time(...[30m])` so load spikes do not trip it.
  - Load averages **48–57 %** with brief spikes to **92 %** → sustained-load rule at 90 % for 30m.
    An `> 80` rule, which looked reasonable, would have fired routinely.
  - Charge floor over 14 days was **95 %** → `< 95` for 6h.

      ⚠️ **Two findings that are worth more than the rules.** First, **`CHRG` is asserted 99.9 % of
      the last 14 days** — "charging never completes" was the best available proxy for the missing
      ALARM, and it is unusable as an alert because it is the steady state. It is still a real
      statement about the pack: it effectively never reaches float. Second, **`RB` has never
      asserted once in 14 days**, so `UpsBatteryReplace` has never had anything to fire on — the
      earlier "RB is under-sampled" theory was wrong, and the flag simply is not being raised.
      Both belong to the battery-health investigation, not to alerting. **Runtime is currently
      468 s at 48 % load on a fully charged pack**, and elizabeth's array stop alone takes ~2 min.

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

**What differed from the design (2026-08-21).** Two assumptions in the phase description above
turned out to be wrong, both discovered by checking rather than by failing:

- **Watchdog-specific alerting is impossible on this hardware.** `iTCO_wdt` reports
  `options: 0x8180` = `SETTIMEOUT｜MAGICCLOSE｜KEEPALIVEPING`, omitting `WDIOF_CARDRESET`. So
  `/sys/class/watchdog/watchdog0/bootstatus` can never say "the watchdog reset me" and will read
  `0` forever. `NodeUnexpectedReboot` alerts on *any* unexpected boot instead — which also catches
  panics and power events, so it is arguably the better signal. It does fire on planned reboots,
  hence the silence requirement noted above.
- **Kernel logs cannot go straight to VictoriaLogs.** Talos emits `json_lines` only; the syslog
  listener accepts RFC3164/RFC5424 only. Since Talos drops silently on an undeliverable
  destination, the original plan would have looked deployed and shipped nothing. Corrected to route
  via the local fluent-bit.

Also worth recording: kernel log shipping captures the **run-up** to a failure, not the fatal
instant — if the node is dying, the shipping path dies with it, and anything logged before
fluent-bit's pod starts is unshippable. The watchdog is the part of this phase that actually pays
the rent; the logging is for naming causes afterwards.

**Two limits of this phase, stated so they are not mistaken for coverage:**

- **The watchdog is verified *armed*, not verified *firing*.** `timeout=300` / `state=active` /
  `feedInterval` were all read back on every node, but nothing has yet made a node actually reset.
  The same applies to `UpsAlarm`'s `!` regex branch. Both are sound by construction and neither has
  been exercised by the real event.
- ⚠️ **Nothing external watches the alerting pipeline, so this phase's alerts cannot report their
  own death.** The `Watchdog` dead-man alert is routed to the `"null"` receiver in
  [alertmanagerconfig.yaml](kubernetes/apps/observability/kube-prometheus-stack/app/alertmanagerconfig.yaml).
  **That routing is correct, not a bug** — the alert always fires, so sending it to Pushover would
  page every 12h forever. The gap is that the null route is the *only* thing consuming it: if
  Prometheus or Alertmanager stops, **every alert added in this phase goes quiet and the silence is
  indistinguishable from health.** gatus cannot cover it either, since it sits on `envoy-external`
  and dies with the cluster.
  - [ ] Route `Watchdog` to an **external** dead-man's-switch endpoint that pages when the ping
        *stops*, keeping the `null` route as the fallback. **Moved to phase 5 and to §8.1 of the
        blackout-monitor design (2026-08-21)** — it belongs with donkey's own heartbeat, because
        the only useful place to run it is a host that does not share the cluster's fate, and
        donkey is battery-backed with its own LTE uplink. Tracked as low priority there; it is
        still the only mechanism that can detect the failure of everything else.

### Phase 2.7 — replace MinIO with garage, and make barman's target trustworthy — ✅ done 2026-08-25

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
host whose stale NFS handles are auto-recovered but not root-caused (phase 1.5), and whose
parity checks saturate it for a day at a time. The most critical backup in the cluster depends on the least reliable machine.

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

- [x] **`data_dir` goes in the existing `backups` share as-is** — `/mnt/user/backups/garage`. It
      is already `shareUseCache="no"` so the mover never touches it, and letting `highwater`
      allocate across disk1 (1.1 TB free) and disk2 (4.6 TB) is fine: garage sees one filesystem
      either way. Pinning to one disk would only trade "one disk dies, lose everything" for "one
      disk dies, lose part", and with `replication_factor = 1` neither is redundancy. Deliberately
      **not** solved here — see the deferred item below
- [x] **Deploy garage via doco-cd — done 2026-08-21** as a per-host compose service (donkey/elizabeth/navi pattern
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
- [x] ~~**Schedule btrfs snapshots of `metadata_dir`**~~ — **built, then deliberately removed as
      over-engineered, 2026-08-21.** What remains is one declarative line,
      `metadata_auto_snapshot_interval = "24h"` in `garage.toml`: garage snapshots its own
      metadata internally, with nothing to monitor and no cron. It caps itself at the two most
      recent — documented and hardcoded, no retention setting, and it prunes anything else in
      that directory including unrelated files.

      The discarded half was a host cron copying snapshots out for 7-day retention. **Do not
      rebuild it.** It added four fragilities for a marginal gain: a script on a vfat filesystem
      that cannot carry an execute bit (`chmod +x` silently no-ops, bare invocation exits 126), a
      cron in a RAM filesystem needing a `/boot/config/go` entry to survive reboots, and an
      unmonitored job — all on the same NVMe pool, so no defence against the disk loss that
      actually threatens this.

      Two bugs found while building it, worth keeping: `garage meta snapshot` self-prunes to two
      entries *before* any wrapper retention runs, which made `KEEP=7` dead code; and sorting
      snapshot directories by mtime pruned a real snapshot while keeping newer-mtime junk,
      because `cp -a` preserves the source mtime. ISO8601 names must be sorted by name.
- [x] Create buckets and access keys for barman (`postgresql`, `immich`), and a second
      `ObjectStore` per cluster pointing at garage. **Keep MinIO serving in parallel** — CNPG
      supports only one plugin objectstore per cluster at a time, so this is a cutover, not a
      dual-write; the parallel period is for rehearsal, not redundancy
- [x] 🔴 **G2 earned against garage — 2026-08-21.** immich-db restored into a throwaway CNPG
      cluster from garage alone, row counts **exactly** matching production (`asset` 60,031,
      `asset_exif` 60,029, `person` 1,887) with every extension intact including `vchord` and
      `vector`. Test cluster and its PVCs deleted; production untouched throughout.

      **The rehearsal justified itself immediately: the first attempt failed, and would have left
      an unrestorable backup nobody knew about.** "Switch the target, then take a base backup
      straight away" is not sufficient — a base backup is only restorable if the WAL segment
      current at its *start* is in the same archive, and right after cutover that segment had gone
      to MinIO. The restore stopped with:

      ```
      encountered an error while checking the presence of first needed WAL in the archive:
        object storage or file not found 000000190000003500000022: WAL not found
      ```

      That backup reported `phase=completed` and sat in the bucket at the right size. **A completed
      backup is not a restorable backup**, and only an actual restore tells the difference — which
      is the entire argument for this gate existing.

      Corrected sequence, now in the plan: switch → force WAL into the new archive and confirm
      `archived_count` rises → base backup → force WAL again → check the Backup's `beginWal`/
      `endWal` sit at or below `last_archived_wal`.

      ⚠️ Two traps while generating that WAL, both of which briefly fooled me into reading a
      broken archive as an idle one: `pg_switch_wal()` is a **no-op on an unwritten segment**, and
      `psql -c` with escaped double quotes turns the payload into an **identifier**, failing
      silently and leaving the counter flat.
- [x] **Both clusters cut over — 2026-08-21.** Order reversed from the original plan: immich-db
      first, because the rehearsal target has to be writing to garage before it can be restored
      from garage. `garage-immich` and `garage-postgresql`, MinIO left commented beside each so
      rollback is uncommenting one line.

      Neither cluster has recorded a **single new WAL failure** since moving, against 22 and 126
      accumulated on MinIO — cluster18 had been failing roughly a quarter of its archives.

- [x] **cluster18 restore rehearsed too, not argued by analogy — 2026-08-21.** The plan said a
      restore proven on immich-db covers cluster18. That was the weaker choice: cluster18 holds
      **Authelia**, so if it is unrecoverable nothing can be logged into, and it had the worse WAL
      record of the two.

      All **15 databases** restored from garage into a throwaway cluster. Across the 10 compared
      programmatically — authelia, lldap, vaultwarden, paperless, atuin, romm, jellyseerr, radarr,
      sonarr, prowlarr — every table matched exactly, including `webauthn_credentials`,
      `totp_configurations`, lldap's 5 users / 6 groups, vaultwarden's 554 ciphers and atuin's
      17,687 store rows. The only two deltas were radarr/sonarr `Commands`, a rolling task queue
      shown to be churning in production between consecutive reads while the restored copy stayed
      frozen.

      ⚠️ Both rehearsal clusters were created with **no `plugins:` block on purpose**. With
      `isWALArchiver` they would have archived their own WAL into the live bucket under the same
      `serverName`, corrupting production's WAL stream. Recovery only ever needs to read.
- [x] **First SCHEDULED backups against garage completed — 2026-08-21 night, verified end to
      end.** Both fired on time and both wrote real data; every prior success had been triggered
      by hand, so this was the actual open question.

      | | started | stopped | object written |
      |---|---|---|---|
      | `cluster18-20260821233000` | 23:30:00 Z | 23:30:33 Z | `postgres18-0/base/20260821T233000/data.tar.bz2` — **46.2 MiB** |
      | `immich-db-20260821234500` | 23:45:00 Z | 23:46:25 Z | `immich-pg17-0/base/20260821T234500/data.tar.bz2` — **509.9 MiB** |

      **Checked the objects in garage, not just the `phase: completed` status** — a status that
      reports success without writing is exactly the failure this phase exists to rule out. Bucket
      totals: `postgresql` 144.3 MB / 270 objects, `immich` 1.6 GB / 62 objects. Continuous WAL is
      flowing too: cluster18 archives every **5 min** like clockwork (266 segments), immich every
      ~10 min in tiny 249 B–1.5 KiB segments (56).
      Confirms the low-write behaviour that shaped the alerting: immich's newest WAL was **95 min
      old** at the time of checking, well inside the legitimate range, which is why
      `DatabaseWALArchiveBacklog` was chosen over a WAL-age rule — an age rule would be pending
      right now for no reason.
- [x] ~~Continue the **full week** watch with the backup alerting armed (through ~2026-08-28)~~
      **Stopped early 2026-08-24 — backups are working, called by decision rather than by the
      calendar.** Verified at the time: both CNPG clusters backed up on their staggered schedule
      (`cluster18` 23:30, `immich-db` 23:45), and all **26** kopiur SnapshotPolicies had a snapshot
      within the preceding few hours with no failures. The backups also survived the phase 3
      rebuild, which restored 21/21 PVCs from them — a stronger proof than another week of
      watching. `DatabaseNoRecentBackup` / `DatabaseNeverBackedUp` stay armed, so a future absence
      is still loud. **MinIO retirement is no longer gated**
- [x] **A "no successful backup" dead-man now exists — done 2026-08-21, mimicking kopiur.**
      `DatabaseFailedBackup` only catches a *recorded failure* and **self-clears after 24h**, so a
      backup that stopped happening altogether went silent within a day and the silence read as
      success. Two rules now in
      [prometheusrule.yaml](kubernetes/apps/database/cloudnative-pg/app/prometheusrule.yaml):
  - `DatabaseNoRecentBackup` — age of the newest **completed** backup > **48 h**, the same
    threshold as kopiur's `KopiurBackupStale`. Backups are daily (23:30 / 23:45 UTC), so it
    tolerates one missed run and fires on two.
  - `DatabaseNeverBackedUp` — a cluster that exists with **no completed backup at all**. This is
    what makes the first rule trustworthy: a staleness check alone cannot tell "backups stopped"
    from "the `Backup` objects were deleted", because when the series disappears the expression
    returns nothing and goes quiet — the exact failure being fixed. `Backup` objects are owned by
    their ScheduledBackup (`backupOwnerReference: self`) and so are prunable, making it a live
    risk. Joining against a per-`Cluster` series makes that case loud.
  - The timestamp comes from the `Backup` objects via **kube-state-metrics
    `customResourceState`** (config in the kube-prometheus-stack HelmRelease), since
    `cnpg_collector_last_available_backup_timestamp` stays **0 even after backups complete**.
    **KSM does parse the RFC3339 `status.stoppedAt` into a Unix timestamp** — verified against the
    live endpoint, which was the one genuinely unknown assumption. Failed backups never set
    `stoppedAt`, so they produce no series at all (`errorLogV: 10` silences the resulting
    per-object nil-path log spam).
  - ⚠️ **Trap worth keeping: the RBAC grant must name every kind referenced.** Granting `backups`
    but not `clusters` left the `Cluster` metrics **silently absent** — KSM logs one `forbidden`
    line and carries on serving every other metric, so `/metrics` looks perfectly healthy and the
    only symptom is a missing series. `DatabaseNeverBackedUp` was therefore **inert on first
    deploy**, and only a **positive control** on the expression revealed it. The old
    `DatabaseNoBackup` failed the same way for two years; the lesson is that an alert expression
    must be evaluated once with a deliberately-true variant to prove it can return anything.
  - Also added for the **continuous** half: `DatabaseWALArchiveBacklog` (WAL segments piling up
    unarchived — write-volume independent, so it stays quiet on an idle database) and
    `DatabaseWALArchiveFailing`. Deliberately **not** alerting on `last_archived_time` age:
    measured with `min by (job)` so only the primary counts, cluster18's worst gap was 9.5 min but
    immich-db's was **399 min**, because a low-write database can take hours to fill a 16 MB WAL
    segment. A threshold loose enough for immich detects nothing useful.
- [x] **MinIO retired 2026-08-25.** The `minio-postgresql` and `minio-immich` ObjectStores are
      deleted from git and pruned from the cluster, leaving only the two garage ones; the container
      is stopped and removed on elizabeth. It was an Unraid **dockerman** container, not doco-cd
      managed, and it was listed in `/var/lib/docker/unraid-autostart` — so stopping alone would
      have brought it back on the next array start. That entry is removed (it was the only one;
      backup taken first). The Unraid template on `/boot` is deliberately left, so it can be
      recreated from the UI if the old data is ever needed.

      **Verified rather than assumed:** an on-demand backup of `cluster18` through the plugin
      completed in 34s with MinIO gone. Note `kubectl cnpg backup` defaults to the *native*
      `barmanObjectStore` method and fails with "cluster has no backup section" — these clusters
      use the barman-cloud **plugin**, so it needs
      `--method plugin --plugin-name barman-cloud.cloudnative-pg.io`.

      Also worth knowing: `status.lastSuccessfulBackup` is **empty on both clusters** because the
      plugin path does not populate that legacy field. The backup alerts do not depend on it —
      they use `cnpg_backup_stopped_at_seconds{phase="completed"}`, verified with controls to
      confirm the `unless on (cluster, namespace)` join in `DatabaseNeverBackedUp` can actually
      match.

#### What still points at elizabeth

The single most load-bearing external host, by a distance. **18 live NFS mounts**, plus:

| dependency | what |
|---|---|
| **S3 / garage** `:3900` | both CNPG ObjectStores — every Postgres backup and WAL |
| **NFS** `:2049` | 17 apps: qbittorrent, radarr, sonarr, prowlarr-adjacent tools, metube, mylar3, pyload-ng, kapowarr, suwayomi, jellyfin, komga, romm, immich, frigate, home-assistant, filebrowser, ocis, paperless |
| **kopiur repository** | the `nas` ClusterRepository — every PVC snapshot |
| **kopia UI** | reads the old VolSync archive (kept, phase 10) |
| **monitoring** | blackbox probes (host + `:2049`), node-exporter `:9100`, an alertmanager route and a silence-operator entry |
| **homepage** | dashboard links |

Nothing in the cluster still references MinIO. The practical consequence is unchanged and worth
restating: **elizabeth down means backups, all media apps, and PVC snapshots stop together.**

- [x] **MinIO frozen, not stopped — 2026-08-21.** Still `Up`, still serving reads, holding **100 GB**
      (immich 66 GB, postgresql 23 GB, plus 12 GB of dead `volsync` bucket). Nothing writes to it:
      both clusters target garage and the only `minio-*` references left in the repo are the two
      commented rollback lines. Deliberately left running per D7 — it is the fixed-point recovery
      source until after the rebuild.

- [x] **Fixed `docker/doco-cd/README.md`, which documented a mechanism that no longer exists.**
      It described SOPS + Age and a `--age-key` flag; the agent has used Bitwarden Secrets Manager
      and `--bws-token` for some time. Also missing the `navi` profile. Now records the traps found
      while bootstrapping elizabeth: hostname must be lowercased (Unraid capitalises it), Docker
      Compose must be checked separately from Docker, `/usr` is RAM-backed so plugin binaries do
      not survive reboot, `external_secrets:` maps env names to Bitwarden UUIDs needing
      `# gitleaks:allow`, and a missing `working_dir` is an error rather than an empty result.
- [x] **Decided 2026-08-25: keep the data for now.** The ~**100 GB** stays at
      `/mnt/disk2/atlantic_minio` on elizabeth, with its config at `/mnt/user/appdata/minio`.
      Deletion is queued in **phase 10** rather than done here — stopping a container is
      reversible, deleting 100 GB of backup history is not.

      Both stated preconditions were in fact met, the first more strongly than the plan asked:
      the phase 3 rebuild on 2026-08-23 **recovered both clusters from garage for real**
      (`wal-restore`, `starting backup recovery with redo LSN 1C8/AC000028`), which beats a
      rehearsal, and scheduled backups have completed cleanly since.

      ⚠️ The recovery path through this data is no longer live: there is no MinIO endpoint, so
      using it means recreating the container from its Unraid template first.
- [x] Fix the monitoring gap while here — **done early, 2026-08-20**, because it was what hid the
      immich-db failure. `DatabaseFailedBackup` could never fire; rewritten onto
      `cnpg_collector_last_failed_backup_timestamp`. Details in phase 2.5

#### Deferred, and genuinely separate: there is no backup of the backups

⏸ **Out of scope for 2.7, tracked here because this is where the evidence turned up.** Every
copy of everything lives on elizabeth, on the same Unraid array:

| what | where | size |
| --- | --- | --- |
| kopiur repository (all 18 app volumes) | `/mnt/disk2/backups/kopiur` | 6.3 GB |
| retired VolSync repository (cold fallback) | `/mnt/user/backups/volsync` | 12 GB |
| barman, after 2.7 | `/mnt/user/backups/garage` | ~88 GB and growing |
| barman, before 2.7 | `/mnt/disk2/atlantic_minio` | 101 GB |

`replication_factor = 1`, one parity disk, one machine, one building. A single array loss, a
second unclean shutdown landing worse than the last one, or anything physical takes **every
recovery path at once** — including the cold fallback that exists precisely to be the last
resort. Parity is not a backup: it survives a disk, not a filesystem, not a mistake, not a fire.

This needs its own design, not a task here. The shape of the question: a second copy somewhere
that is not elizabeth — another host, off-site, or a cloud bucket for the small-but-critical
subset (CNPG base backups are the only truly irreplaceable data; media is re-acquirable). Garage
is actually built for exactly this — it is a *geo-distributed* store, so a second garage node
elsewhere replicating the barman bucket is the native answer, and 2.7 deliberately sets
`replication_factor = 1` now rather than pretending otherwise.


### ⚠️ Open now — belongs to no phase, both found 2026-08-21

Two live Ceph issues, surfaced while unblocking Flux during phase 2.7. Neither is caused by the
garage migration; both need a decision.

- [x] ✅ **RESOLVED — the mgr crash loop is fixed by PR #467** (Rook v1.20.2→v1.20.6, Ceph
      v20.2.3→v20.2.4), merged 2026-08-21.

      ⚠️ **Two wrong conclusions were reached before the right one, both from extrapolating a
      burst.** First the upgrade looked successful because the mgr restart reset the counter.
      Then, seeing 6 crashes in a 75-second window, it was recorded here as "NOT fixed, ~4 per
      minute" — but those 6 all fell between 09:59:26 and 10:00:41, *during the daemon roll*.
      Measured properly afterwards: **0 `node_proxy_fullreport` errors and 0
      `NotImplementedError` in the following 2 hours**, and 0 new crashes across a 90-second
      sample. Rate is not a thing you can infer from a burst; it has to be measured over a window
      that excludes the event you are recovering from.

      The chain: the `prometheus` mgr module's `get_hardware_metrics()` calls
      `node_proxy_fullreport()`, which the Rook orchestrator does not implement → a crash report
      every ~15 s → reports arrive faster than the `crash` module can iterate → `dictionary
      changed size during iteration` → the module fails → **HEALTH_ERR** → `rook-ceph-cluster`'s
      health check fails → **31 Kustomizations stall** on `dependency ... is not ready`. Measured
      twice today: about **one hour** from clean to blocked.

      Not an outage when it happens — mons, OSDs, MDS and the data plane stay healthy, 190 pods
      keep running. What breaks is GitOps: no Flux change can land.

      That was the pre-upgrade behaviour, and it is worth keeping because it explains how a
      cosmetic mgr fault becomes a GitOps outage: crash reports arrive faster than the `crash`
      module can iterate, so the module fails, health goes ERR, and **31 Kustomizations stall**
      on `dependency 'rook-ceph/rook-ceph-cluster' is not ready`. Never an outage — mons, OSDs,
      MDS and 190 pods stayed healthy throughout — but no Flux change could land.

      Mitigations considered and now unnecessary, recorded in case it returns: raising
      `mgr/prometheus/scrape_interval` (15 s → 60/300 s, at the cost of staler Ceph metrics), or a
      CronJob running `ceph crash archive-all` every 30 min. Disabling the `prometheus` mgr module
      was rejected outright — the `rook-ceph-mgr` ServiceMonitor feeds `ceph_health_status` and
      every Ceph alert, so it would blind the monitoring that surfaced the problem.

      Final state: health is `HEALTH_WARN` from the CVE auth checks alone, and all Kustomizations
      are Ready. **#488 (Ceph v21.1.0, Renovate-flagged breaking) remains a separate decision and
      should not be merged casually.**

- [x] ~~🔴 **CVE-2025-30156 — cephx keys are the old insecure `aes` type, and the ERR is muted
      until 2026-08-28.** Ceph v20.2.4 exists largely to fix this CVE; it introduces the
      `aes256k` key type, and the new `AUTH_INSECURE_*` health checks are the intended signal
      that existing keys must be rotated. Ours are all `aes`: 8 client entities (`client.admin`,
      the four CSI identities, `client.crash`, `client.ceph-exporter`,
      `client.rbd-mirror-peer`), 6 service entities, and 4 rotating service keys.~~
      **Moot since phase 3 (2026-08-23): Ceph is gone**, and with it every cephx key.

      `AUTH_INSECURE_SERVICE_KEY_TYPE` is **ERR** level, which blocks Flux the same way the crash
      loop does, so it is muted with `ceph health mute ... 7d` — **deliberately time-boxed so it
      returns rather than being silenced for good.**

      Rotation touches cluster authentication and the CSI drivers, so it needs its own session,
      not a tail-end action: Rook documents a managed cephx rotation path, and Ceph notes daemons
      and clients keep using the old type internally for two to three hours after a rotation.


### Phase 3 — the rebuild: destroy the cluster, drop Ceph, rename the nodes — ✅ done 2026-08-23

One planned outage that fixed four things at once. Ceph is gone, the nodes have honest names,
etcd has a third member, and the 50 GiB `/var` cap that bit three times is gone.

**Verified at completion:** 5/5 nodes Ready on Talos v1.13.8 / Kubernetes v1.36.3, **etcd at
3 members**, 90/90 Kustomizations, 74/74 HelmReleases, 163/163 pods, **21/21 kopiur restores
`Completed`**, both CNPG clusters healthy at 2/2, 41 miroir volumes, 633 snapshots. **No PVC
came up silently empty** — the `onMissingSnapshot: Continue` risk did not materialise.

#### The hardware, as built

| node | IP | role | model | system disk | miroir pool |
|---|---|---|---|---|---|
| `bulbasaur` | 10.1.10.10 | control plane | NUC10i5FNH, 8 / 32 | Samsung 970 EVO+ 500GB | loopfile, 263 GiB |
| `charmander` | 10.1.10.11 | control plane | HP EliteDesk 800 G4 DM, 6 / 16 | WDC SN720 256GB | loopfile, 136 GiB |
| `squirtle` | 10.1.10.12 | **control plane (new)** | M720q, 6 / 16 | SanDisk SD9TB8W2 256GB | `lvmthin` on WD_BLACK SN850X, 929 GiB |
| `magikarp` | 10.1.10.21 | worker | M720q, 6 / 16 | KINGSTON SA400S3 120GB | `lvmthin` on Crucial P3, 929 GiB |
| `snorlax` | 10.1.10.23 | worker | M720q, 6 / 16 | SanDisk SD9TB8W2 256GB | `lvmthin` on WD_BLACK SN850X, 929 GiB |

EPHEMERAL: 200 GiB on bulbasaur, squirtle and snorlax; 100 on charmander; 90 on magikarp.

**Three deliberate changes from the design.**

- **The third control plane is at `.12`, not `.22`.** Control planes live in the `.1x` range,
  so the machine moved address as well as name. The disk rationale held: it is a SanDisk
  system disk, not magikarp's DRAM-less KINGSTON SA400S3, which stayed a worker.
- **`miroir-replicated` is replicas 2 with `quorum: freeze`, not replicas 3.** Upstream's
  intended topology is two diskful legs plus an automatic **diskless tie-breaker**, which
  gives 3 votes without putting every write on the QLC Crucial P3. `last-man-standing` was
  rejected because such volumes *never* get a tie-breaker, leaving permanent split-brain
  exposure.
- **Node names are Pokémon.** `magikarp` is the KINGSTON-disk worker; the three starters are
  the control planes.

#### Gates

- [x] **G1** — phase 2.5 complete
- [x] **G2** — accepted on its earlier rehearsal rather than re-run, by explicit decision
- [x] **G3** — the `nas-volsync` ClusterRepository was removed from git on 2026-08-24, but the
      **data on elizabeth is deliberately kept** for now as the cold second copy
- [x] **G4** — recovered essentially unassisted. Flux was never suspended and no restore was
      hand-ordered. Everything that needed a hand is below

#### What needed hand-holding (G4)

Five faults during the outage, **none of which were in the plan**, all now fixed in git:

| fault | cause | fix |
|---|---|---|
| PXE dead, all five nodes stranded | firewall hardening `f304ac4` dropped the blanket `established` rule; udp/69 was never allow-listed | `self_tftp` rule in `infra/opnsense_firewall.tf` |
| `pvcreate` refused the NVMe | Ceph BlueStore signature **survived `--wipe-mode all`** | `talosctl -n <ip> wipe disk nvme0n1 --insecure` |
| miroir `lvmthin` pools would not create | module name is `dm-thin-pool`, not `dm_thin_pool` — the underscore form applies cleanly, loads nothing, and survives a reboot doing nothing | hyphenated name in `patches/global/machine-kernel.yaml` |
| three miroir agents hung on a read-only `/var/mnt/local-hostpath` | EPHEMERAL sized in **GiB against GB** disks, leaving less than the 50 GiB user-volume floor | floor lowered to 10 GiB |
| charmander would not netboot | iPXE's **native** NIC driver cannot bring up link on the HP; the firmware's own PXE stack had just TFTP'd the binary over that same NIC | build `snponly.efi`, which uses the firmware's SNP driver |

Three interventions after Flux took over, all self-inflicted by cold start rather than by the
design:

- **`letsencrypt-production` cached a failure** from before its ExternalSecret existed and
  never retried. An annotation forced re-evaluation. The ESO/cert-manager cycle itself is
  correctly broken by the selfsigned `bitwarden-bootstrap-issuer` — this was ordering, not
  deadlock
- **Six HelmReleases hit `context deadline exceeded`**, purely because frigate's 1.8 GB image
  took **24 minutes** to pull. `flux reconcile hr --force` cleared all six
- **unifi `ImagePullBackOff`** resolved itself once Spegel's empty cold-start mirror fell back
  upstream

#### The reset mode matters more than it looks

`--wipe-mode all` was needed here **only** to clear the Ceph BlueStore signatures. It also
destroys the ESP, and that has a consequence worth knowing before the next reset:

**Talos ≥ v1.11.0 writes a `Talos Linux UKI` EFI boot entry on install and never removes it on
reset.** Verified in the source — `CreateBootEntry` is called from `setup()` on both Install
and Upgrade, `DeleteBootEntry` is called only from inside `CreateBootEntry`, and nothing in the
reset sequencer touches EFI variables. The feature landed in commit `378fe4f`, an ancestor of
`v1.11.0` and absent from `v1.10.0` — which is why resets on older Talos used to fall through
to PXE cleanly. There is no config knob, no reset flag, and efivarfs is mounted `ro`, so the
entry cannot be removed from a running node.

After a full wipe the entry dangles at a partition UUID that no longer exists, and HP's
firmware halts at `3F0` rather than falling through — the failure that cost charmander hours.
It self-heals on reinstall, since `CreateBootEntry` reuses the lowest-indexed Talos entry and
deletes duplicates.

**So: prefer `--system-labels-to-wipe EPHEMERAL,STATE`** — what `just talos reset-all-nodes`
already does. It keeps other partitions intact, so the bootloader survives, the entry stays
valid, and the node boots from its own disk into maintenance mode with **no PXE involved at
all**. Reach for `--wipe-mode all` only when disk signatures or partition sizes must change,
and expect a manual boot-menu press on the HP.

Secure Boot was ruled out as a contributor: `SecureBoot=00` on all five, and the firmware
loaded our unsigned iPXE binaries without complaint. Note that charmander is the only node
with `SetupMode=00` — the HP factory reset enrolled a Platform Key — so it is the one machine
where enabling Secure Boot in BIOS would immediately refuse both the unsigned Talos UKI and
unsigned iPXE, and strand it.

#### Still open

- [x] **Benchmarked 2026-08-24** — numbers below
- [x] Deleted `downloads/prowlarr-rescue` — no `*-rescue` PVC remains in any namespace
- [x] Runbook updated with the two reset modes and the `wipe disk` step
- [x] **G3 — repository removed, data kept (2026-08-24).** The `nas-volsync` ClusterRepository
      and its `volsync-repo` ExternalSecret are gone from git, so Flux pruned them; nothing
      referenced them (all 26 SnapshotPolicies write to `nas`). **The folders on elizabeth are
      intentionally left in place**: `/mnt/user/backups/volsync` (18G, last write 2026-08-19) and
      `/mnt/user/backups/volsync-preblackout-20260818` (17G). 35G total, recoverable by reverting
      the commit — re-add the ClusterRepository and the archive is browsable again
- Deleting those 35G from elizabeth is deferred to **phase 10**.
- Tracked in **🔴 Urgent** at the top: charmander's 100 Mbit link. Detail below.
- [x] ✅ **power-nap-over fixed 2026-08-24** — root cause was doco-cd, see below

#### Benchmark — the write path is network-bound, not disk-bound

fio on snorlax (WD_BLACK SN850X), `direct=1`, 30s per test, 2026-08-24:

| test | `miroir-local` (1 copy) | `miroir-replicated` (2 copies) | penalty |
|---|---|---|---|
| randwrite 4k qd16 | 137,913 IOPS / 539 MiB/s | 20,599 IOPS / 80 MiB/s | **6.7× slower** |
| seqwrite 1M qd8 | 3,107 MiB/s | 111 MiB/s | **28× slower** |
| randread 4k qd16 | 150,090 IOPS / 586 MiB/s | 143,003 IOPS / 559 MiB/s | ~none |

**Reads are essentially free** — DRBD serves them from the local leg, so replication costs
nothing there. **Writes are capped by the network, not the QLC concern the design flagged.**
111 MiB/s is 1 GbE line rate: every node is `1000Mbit`, so a replicated sequential write cannot
exceed roughly that no matter which NVMe backs it. The Crucial P3's QLC endurance is still worth
watching, but it is **not** what limits throughput today — the single biggest storage win
available is a faster replication link, not a better disk.

#### 🔴 charmander is on a 100 Mbit link

Found while establishing the above. `eno1` on charmander negotiates **100Mbit/Full** while all
four other nodes are at `1000Mbit`. Nothing in `patches/` forces a speed, so it is autonegotiated;
the link is clean (zero errs, drops, carrier events on `/proc/net/dev`), which points at **cabling
or the switch port**, not the `e1000e` driver.

It matters more than a worker would: charmander is a **control plane running etcd**, and it also
hosts a miroir loopfile pool. It may also be related to the phase 3 boot trouble — iPXE's native
driver could not bring the link up on this machine at all.

Next step: reseat/replace charmander's cable and check the switch port, then re-verify with
`talosctl -n 10.1.10.11 get links eno1`.

#### 🔴 power-nap-over never picked up the renames

The blackout recovery service on donkey is **still configured with the old node names and the
old addresses**. Its live config — the named volume `power-nap-over-config`, which is what the
container actually mounts at `/app/config` — lists `kube-nuc`, `kube-hp`, `kube-ceph-01/02/03`
and still has **`kube-ceph-02` at `10.1.10.22`**, an address that no longer answers. That node
is squirtle at `.12`, and it is now a **control plane** while the stale config still has it in
the priority-3 *Workers* group.

**The generator is not at fault.** `scripts/generate-config.sh` reads `.hostname`, `.ipAddress`
and `.controlPlane` straight out of `talconfig.yaml`, plus elizabeth from `networks.yaml`, and
writes `broadcast_ip: 10.1.10.255`. Run today it would produce a correct file. The problem is
that it runs **only as an init container when the compose stack is deployed**, and the stack has
not been redeployed since the renames — the container has been up 4 days.

Consequence on a real power event: PNO would ping a dead `.22`, wake squirtle in the wrong group,
and report the old names. Worth weighing against [[project_pno_rewrite]] — PNO recovered nothing
on 2026-08-17, and a config this stale is a candidate contributor.

**Fixed 2026-08-24 — and the real cause was not PNO at all.**

doco-cd on donkey had been **failing every 3-minute poll for six days**, since 2026-08-19 17:25:

```
failed to clone repository: failed to fetch repository: All attempts fail:
#1: ref file is empty
```

Every one of the 32 files under `.git/refs/remotes/origin/` was **zero bytes**, all stamped with
that same minute, and there was no `packed-refs` to fall back on. `refs/heads/main` was intact,
which is why `git log` worked while go-git's fetch died. A truncated write — consistent with an
unclean shutdown. Donkey's checkout was stuck at `72b7af2`, **152 commits behind**, so *every*
docker service doco-cd manages there was frozen, not just PNO. PNO's stale config was a symptom.

Fix: delete the empty remote refs (git recreates them on fetch — surgical, and it preserves the
working tree that PNO bind-mounts its `logs` from), then restart doco-cd. It pulled straight to
`ffdf240`, the init container regenerated the config, and after restarting `power-nap-over` it
reports **1/1 NAS, 3/3 control plane, 2/2 workers, all online** — where before it logged
`OFFLINE: kube-ceph-02 (10.1.10.22)` on every sweep.

**Fleet check — the same corruption was on navi**, also 32 empty refs, also cleared. elizabeth was
clean and already current. Two things remain:

- Tracked in **🔴 Urgent** at the top: navi's doco-cd crash-loop on a rejected Bitwarden token.
  Its refs were fixed here; the token is the remaining blocker
- [x] ✅ **doco-cd is now scraped and alerted — done 2026-08-25.** The endpoint existed on 9120
      all along; the compose published no ports, so nothing could reach it. Port published on all
      three hosts (one profile per host, so no contention), `ScrapeConfig` added, four rules in
      `prometheusrule-doco-cd.yaml`. All three targets `up=1`, all four rules `health=ok`.

      The load-bearing one is **`DocoCdPollStalled`**: `doco_cd_polls_total` counts **successful**
      polls, so a flat counter is exactly the signal `Up (healthy)` cannot give — process alive,
      sync dead. Interval is 3m, so 30m should hold ~10 increments.

      Two things worth recording because they are easy to get wrong:
      - **`DocoCdRestarting` uses `resets()` on the counter, not `changes(doco_cd_info)`.** A
        restart changes the `start_time` **label**, creating a new series rather than changing a
        value, so `changes()` would never fire. It matters because `increase()` accounts for
        counter resets, so a crash-looping instance could otherwise keep `DocoCdPollStalled` quiet.
      - **Verified with deliberately-true controls**, per [[reference_alert_rule_verification]]:
        `>= 0` returns rows for every host, proving the expressions and their joins can return
        anything, while `== 0` is empty in steady state. Immediately after the container recreate
        the `== 0` form *did* match — the counter sits at 1 with nothing to diff — and it cleared
        on each host's second poll, inside the `for: 15m` window. So the restart case is covered
        rather than merely unobserved.
- [x] **doco-cd upgraded 0.103.0 → 0.112.0 on all three hosts — done 2026-08-25.** Not v0.111.0:
      v0.112.0 landed the same day and pinning a superseded version would reopen this immediately.
      Checked the range for behavioural changes rather than bumping blind, since a doco-cd schema
      change has bitten this repo before: **v0.107** flipped the `auto_discovery.delete` default to
      `false` (all three configs set it explicitly, unaffected) and **v0.111** made `.env` files
      expand `${...}` including bash-style operators (no `.env` is tracked, and the only one in the
      deployed checkout is a `.env.example` with no placeholders).

      **Rolled one host at a time, and the canary earned its keep.** donkey came up on 0.112.0 and
      failed every poll with `failed to update submodules: services/peekaboo: upload-pack: not our
      ref f8e55b7f…`. Rolling back to 0.103.0 did **not** fix it — which is what proved the agent
      was innocent and the fault was in the committed tree.

      Cause: a `git add -A` in commit `a93f1d5` moved the `services/peekaboo` submodule pointer
      from `ddb6a34` to `f8e55b7`, a commit that does not exist in `adumat/peekaboo` (GitHub
      returns 422). It broke GitOps on **all three** hosts, not just the one being upgraded,
      because the bad pointer was in `main`. It stayed latent until a container recreate forced a
      fresh clone — doco-cd's cached checkout kept working until then, which is why the earlier
      monitoring work saw healthy polls.

      Fixed by restoring `ddb6a34` and running `git submodule update` so the working tree matches
      the index — the local submodule sitting at a different commit is how `add -A` picked up a
      bogus gitlink at all. 0.112.0 then polled cleanly on all three.

      **Lesson worth keeping: never `git add -A` in a repo with submodules.** Stage explicit paths.
      A stale local submodule checkout is invisible in `git status` output that scrolls, and the
      resulting breakage lands on every consumer of the branch.

      Tuned while rolling out: `DocoCdRestarting` now needs **>1** reset in 30m. Every planned
      upgrade is one reset, and alerting on that would raise a warning for each maintenance window;
      a crash-loop is ~30 resets, so the signal is untouched.

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
- [x] ~~**Ceph mgr module crashes hold `HEALTH_WARN` permanently — consider v20.2.4.**~~
      **Moot since phase 3 (2026-08-23): Ceph is gone.** The `rook` mgr module's
      `NotImplementedError` in `node_proxy_fullreport`, ~5,700 crash reports a day holding the
      cluster in `HEALTH_WARN`, disappeared with the storage layer it belonged to.
- [ ] ⚠️ **External dead-man for the alerting pipeline — implement §8.1 of the blackout-monitor
      design.** *Low priority, and deliberately deferred to that project rather than done here:
      it only works from a host that does not share the cluster's fate, which is donkey.*
      Phase 2.6 ends with the cluster unable to report the death of its own alerting. The
      `Watchdog` alert fires permanently by design so that an outside observer can treat its
      *absence* as "monitoring is dead", but it routes to the `"null"` receiver and **`null` is
      the only consumer**. If Prometheus or Alertmanager stops, every alert in the cluster —
      including all of phase 2.6's — goes quiet, and the silence is indistinguishable from
      health. The `null` route itself is **correct** and must stay as the fallback; paging on an
      always-firing alert would page every 12h forever.
      Work: an Alertmanager receiver with `webhook_configs` → a Healthchecks ping URL (Bitwarden
      → ExternalSecret), the `Watchdog` route moved onto it, and the check living in **donkey's
      own Healthchecks project** so one place answers "is the house alive, and is the monitoring
      alive". Grace period must **exceed `repeatInterval`** or a healthy cluster flaps the check.
      ⚠️ Do **not** invert this into donkey polling Prometheus: a pull check traverses glados and
      the cluster network, so it fails for reasons unrelated to Prometheus being dead — the same
      false-signal trap as `vpn.${DOMAIN}` after an outage. Push, with the timeout owned
      externally. Full rationale and the dependency-inversion caveat in §8.1 of
      `docs/superpowers/specs/2026-08-18-power-monitoring-and-emergency-access-design.md`.
- [x] **ESPHome config moved into git — done 2026-08-22.** All four live devices now pull their
      configuration from `esphome/` in this repo via ESPHome's official **remote packages**; the
      `esp-home` PVC keeps only thin stubs plus `secrets.yaml`. The dashboard still compiles, flashes
      and streams logs — it is simply no longer the author of record. Design and plan under
      `docs/superpowers/`.
      Chosen over three homegrown alternatives (ConfigMap read-only mounts, an initContainer copy, a
      CronJob pushing the PVC to GitHub) because it is the **supported** mechanism and it keeps the
      dashboard fully working.
  - Secrets **cannot** leak by accident: ESPHome forbids `!secret` inside a remote package, so stubs
    read `!secret` and pass substitutions in, and `/config` is never committed. That also disarmed
    the three dead configs holding **inline** credentials without having to touch them.
  - `power-outlet` 127→32 lines, `iron-outlet` 173→69, `hvac-controller` 510→15,
    `intercom-controller` 203→15. All four on ESPHome 2026.7.3 (from 2026.5.3).
  - **The two 1 MB plugs are no longer near the OTA ceiling**: `web_server` removed took them
    501,520→482,480 and 503,472→484,400, about **−19 KiB each**. They had ~16 KiB of headroom and a
    version bump could have exhausted it — a too-large image builds fine then fails to upload,
    costing USB access to a wall socket.
  - **`safe_mode` added to every device** (none had it): a boot-looping device is now recoverable
    over the air instead of over USB. It cannot protect the OTA that *installs* it, so each device's
    first flash was the only genuine physical-access risk. On the plugs it made the image ~50 bytes
    **smaller**.
  - ⚠️ **The one rule that matters: a stub must never duplicate a key its package defines.** Local
    values win **permanently and silently** — you edit the repo, compile, and see no change with no
    warning anywhere. Recorded in `AGENTS.md` and `esphome/README.md`.
  - Deliberately left alone: the five dead YAMLs in `/config` (three of which hold inline
    credentials, harmless now that the directory is never committed), and CI validation via
    `esphome/build-action` — it cannot see the stubs or secrets, and the dashboard compile catches
    the same errors immediately.
  - ⚠️ **Do NOT adopt the official "publish firmware to GitHub Pages" pattern.** It is for public
    projects where each user supplies their own secrets; personal firmware has the **WiFi PSK and
    API key compiled into the binary**, so publishing artefacts from a public repo would leak them
    in a downloadable `.bin`.

      **Five traps found by executing it, each of which made a healthy system look broken:**
  - `esphome config` prints resolved secrets in **plaintext** when output is not a TTY — the ANSI
    conceal escapes only hide them interactively. Never redirect a full dump anywhere, and never use
    `grep -B/-A/-C` on it.
  - `.device-builder-devices.json` is **dashboard-managed**; the CLI never updates it, so it reports
    the old version forever after a CLI flash. Read the device's boot banner instead.
  - ESPHome resolves `!secret` relative to the **config file's own directory**, so validating a copy
    in `/tmp` fails looking for `/tmp/secrets.yaml` — and surfaces as a YAML parse error.
  - A long foreground `kubectl exec -- esphome compile` **deadlocks**: the remote process outlives
    the client, blocked writing to a dead pipe. Run detached and poll.
  - **`ps` does not exist in the esp-home container**, so `ps aux | grep -c` greps empty input and
    returns `0` — a false "build finished" signal. Scan `/proc/[0-9]*/cmdline` instead.

      Unlocks the **PS5 wake device**, which can now be built this way from the start: config in
      `esphome/devices/`, custom BR/EDR component in `esphome/components/` via `external_components`
      from a git source. Separate plan, own hardware prerequisites.
- [x] **PS5 wake device — WORKING 2026-08-27. It powers the console on from fully off.**
      Confirmed on hardware: pressing `wake` on `ps5-wake.lan` turned a powered-off PS5 on.
  - **The mechanism is the baseband PAGE, not L2CAP.** Paging the console from a BD_ADDR it
      recognises is the entire trick — no L2CAP channel, no link key, no HID reports. Every
      `no l2cap open (after 5 attempts)` in the logs is **noise**: those were ten successful pages,
      and the first almost certainly did the job. The design's PSM 0x11/0x13 framing was the wrong
      layer, inherited from the upstream reference it cited.
  - Independently corroborated by `github.com/AuRoN89/ps5-bt-wake` (CC BY 4.0, so usable with
      attribution — unlike `blow05/esp32_ps_wake`, which has no licence at all): it spoofs the pad
      MAC, sends a raw HCI `CREATE_CONNECTION`, restores the MAC, and states plainly that no link
      keys, pairing info or HID reports are needed. That project also derives the console's
      Bluetooth address as the Wi-Fi MAC ±1, matching our captured value exactly.
  - **Working configuration:** `pad_mac` = `A0:AB:51:B1:23:7B` (a DualSense genuinely bonded to
      this console), `ps5_mac` = `80:60:B7:10:03:3F` (captured, = Wi-Fi MAC + 1).
  - ⚠️ **`ACL from …` is NOT the success signal** — it only appears when the console is already
      awake, and its absence is expected on a successful wake. Do not treat the L2CAP result as an
      outcome; the only reliable confirmation is the console itself. This misled diagnosis for hours.
  - ⚠️ **Which pad matters.** `4C:B9:9B:9F:0E:81` produced total silence (no ACL, pure page
      timeout) — it was never bonded to this console. `A0:AB:51:B1:23:7B` works. Note that
      connecting a pad to another host (a Mac) re-keys it, and its HID report `0x09` then names that
      host, which is why reading the console's address from a pad never worked.

      **Follow-ups now that it works:**
  - [ ] **Strip the L2CAP layer.** It contributes nothing to the wake and is the most fragile code
        in the component — the retry loop, the VFS registration, the security flags, the callback.
        A page-and-stop implementation would be far smaller and reclaim flash (currently 82.5%).
  - [ ] `last_result` should report **"page sent"**, not an L2CAP verdict. As written it reports
        failure on a successful wake, which is actively misleading.
  - [ ] Wire it into **power-nap-over** so a UPS recovery can wake the console — the original point.
  - [ ] Move it to a **non-UPS outlet**, per the design: the device must survive the cut it exists
        to recover from.
  - [ ] Consider dropping `api:` and setting `level: INFO` again to reclaim RAM, now that bring-up
        no longer needs verbose logs (free heap at setup was 120,956 against a 120,000 gate).
- [x] **PS5 wake device — hardware live, reaching the console, rejected on identity (2026-08-26).**
      Flashed and running at `ps5-wake.lan` / `10.1.30.34`. Everything up to the Bluetooth link
      layer works; the console answers and then refuses us.
  - **The console's Bluetooth address is `80:60:B7:10:03:3F`** — captured, not guessed. Note it is
      the **Wi-Fi MAC + 1** (`80:60:b7:10:03:3e`), same OUI, consecutive. The PS5 exposes neither in
      a way that helps: System Information lists LAN and Wi-Fi only.
  - **How it was captured, since nothing else worked.** The pad route failed twice: a DualSense
      stores one host, and connecting it to a Mac over Bluetooth *makes the Mac its host*, so HID
      feature report `0x09` could only ever return the Mac's controller address. Inquiry failed too
      — on Settings → Accessories → Bluetooth Accessories the console is **scanning, not
      advertising**, so a scan from our side returns 0 devices. The answer was to invert it: the
      ESP32 goes discoverable as `PS5-Wake`, you select it on the console, and the address arrives
      in `ESP_BT_GAP_ACL_CONN_CMPL_STAT_EVT` when the link opens — **before** any pairing outcome.
      The pairing is expected to fail and does not matter. Owner's idea, and the only one that worked.
  - 🔴 **Current blocker: `stat=271` = `0x10F` = `ESP_BT_STATUS_HCI_HOST_REJECT_DEVICE`**, HCI error
      0x0F, *"Connection Rejected due to Unacceptable BD_ADDR"*. The ACL link to the console **does**
      establish — `ACL from 80:60:B7:10:03:3F` — and is then torn down. Crucially this is **not**
      `AUTH_FAILURE` (0x105), `KEY_MISSING` (0x106) or `HOST_REJECT_SECURITY` (0x10E): we never reach
      authentication. The console rejects the **identity**, which makes this a bond-list problem
      rather than the HID-session/link-key wall the design predicted.
  - **Next test, cheap and no rebuild:** we spoof `A0:AB:51:B1:23:7B`, which is the pad that was
      connected to a Mac and whose console-side standing is therefore doubtful. Try the other pad,
      `4C:B9:9B:9F:0E:81`, keeping `ps5_mac` at `80:60:B7:10:03:3F`. If the link is accepted, the
      technique works and the only error was which pad we impersonated.
  - ⚠️ **BR/EDR sniffing needs real hardware** (Ubertooth-class) because it frequency-hops; cheap
      nRF sniffers are BLE-only and Bluedroid has no promiscuous mode. Only worth it if a
      genuinely-trusted address is *also* rejected.
  - ⚠️ **A captured address does not survive an OTA** — `restore_value` restores the last value
      actually flushed to flash, and a fresh capture reverted to the previous value across a
      reflash. Re-set `ps5_mac` after any OTA, or make capture persist immediately.
- [x] **PS5 wake device — component written and compiling (2026-08-22).** A dedicated ESP32 that
      wakes the PS5 by impersonating a paired DualSense over Bluetooth Classic, because a UPS output
      cut leaves the console **fully off** and Sony's network wake needs Rest Mode. Design and plan
      under `docs/superpowers/`; component at `esphome/components/ps5_wake/`, device at
      `esphome/devices/ps5-wake.yaml`.
      **Compiles clean from the git source with nothing local** — flash 76.6%, static RAM 67.0%.
      Built the new GitOps way from the start: stub on the PVC, device config as a remote package,
      and the custom C++ component pulled via `external_components` from this repo.
  - ⚠️ **Two ESP-IDF Kconfig gates that are not obvious and cost a cycle each.** Bluetooth Classic
    ships **disabled**: `CONFIG_BT_ENABLED` defaults `n`, and even with it on
    `CONFIG_BT_CLASSIC_ENABLED` **also** defaults `n` (only BLE defaults on). Then L2CAP needs a
    **third** opt-in, `CONFIG_BT_L2CAP_ENABLED`, which `depends on BT_CLASSIC_ENABLED` and is *still*
    `default n`. Both are now set from the component's `to_code()` via `add_idf_sdkconfig_option`.
    The two failures look completely different and that is the useful tell: a **missing header**
    (`esp_bt.h: No such file or directory`) means Bluetooth is off, because ESP-IDF's `bt` component
    only publishes its `INCLUDE_DIRS` under `if(CONFIG_BT_ENABLED)`; an **undefined reference at
    link** means the API is declared but its implementation was compiled out.
  - ⚠️ **The premise is unverified by choice.** The whole device rests on a physical DualSense being
    able to wake this console from fully off, not merely from Rest Mode. The go/no-go test was
    skipped. The ESP32 can do exactly what the pad can do and no more.
  - ⚠️ **And a sharper risk than "will it connect".** A real DualSense presents a HID descriptor and
    exchanges reports; this device only opens L2CAP on PSM 0x11 and 0x13. If `last_result` says
    `no l2cap open after 5 attempts` the connect is refused; if it says `wake sent` and the console
    stays asleep, the link opened but the console wanted a HID session — and emulating that is well
    beyond current scope.
  - Remaining, all needing the board on site: flash it over USB; **calibrate
    `min_heap_for_always_on`** from what `free_heap` actually reports (the `120000` in the config is a
    guess, and static RAM is already at 67% before Bluedroid allocates its 60–100 KB); add a DHCP
    reservation at **`10.1.30.34`** on **IoT VLAN 30** once the MAC is known; and enter both MACs on
    the web config page.
    ⚠️ **The VLAN was wrong in the original design and is corrected here.** It joins the same SSID as
    the other ESPHome devices, and **SSID determines the VLAN** — a reservation cannot move a host
    between VLANs. Flashed 2026-08-25 and came up at `10.1.30.113` from the IoT pool. `.30`–`.33` are
    the existing four devices so `.34` is next free. Guest isolation still holds (guests reach only
    `10.1.30.16/28`) and `servers → iot` already permits what is needed, so **still no firewall
    change**. The MAC must be read from the device's web page or the OPNsense lease table — donkey
    cannot ARP across VLANs, and the web_server v3 UI does not expose it in served HTML.
    ⚠️ Read the PS5's **Bluetooth** MAC from Settings → System → System Information, *not* its LAN
    MAC. And **do not pair the DualSense to a computer to find its address** — a DualSense remembers
    only one host, so pairing it elsewhere unpairs it from the PS5 and destroys the very bond this
    device rides. Read it over USB via HID feature report `0x09`.
- [ ] **Rotate every ESPHome per-device credential.** Each device has its own
      `<device>_api_encryption` key and `<device>_ota_password` in `secrets.yaml` on the `esp-home`
      PVC, plus the shared `wifi_password` and `fallback_hotspot_password`. **None has ever been
      rotated.** They have sat in cleartext on a volume for the life of the cluster, and three
      now-dead device configs additionally carried them **inline** rather than via `!secret`.
      Rotation was previously expensive — hand-edit a YAML in the dashboard, hope the OTA lands.
      Since the 2026-08-22 migration it is cheap: change the value in `secrets.yaml`, and the
      device's stub picks it up on the next compile from the shared package.
      Do all of them in one pass rather than singly, so there is one Home Assistant reconciliation
      instead of several — **changing an `api_encryption` key requires updating that device in the
      Home Assistant ESPHome integration too**, or HA loses the device until it is re-paired. Order
      each device as: new value in `secrets.yaml` → compile → OTA → update HA → verify entities.
      Do the OTA password and API key in the *same* flash per device; a device that takes the new
      API key but keeps the old OTA password is fine, the reverse is not.
      ⚠️ Treat every one of these as compromised-until-rotated rather than reasoning about which
      individually matter. They are local-network credentials behind the firewall, so the practical
      exposure is low, which is why this is not urgent — but it is also why it keeps being deferred.
- [ ] `snmp-exporter` — HPE OfficeConnect 1820 switch and the UPS, invisible today
- [ ] `drm-exporter` — Intel GPU utilisation, invisible today even though frigate and
      jellyfin transcode on it
- [ ] Evaluate NUT **in cluster**: today the server runs on donkey under Docker and only
      the exporter runs in the cluster
- [ ] Pick up the MinIO metrics scrape from elizabeth (see Follow-ups): it is the same gap,
      and it is what forced the CNPG failures to be diagnosed by hand-querying VictoriaLogs

#### The three Docker hosts are half-observed, and it already cost six days

The cluster is well covered; the Docker side is not. Measured 2026-08-24, the `node-exporter`
ScrapeConfig holds `donkey.lan:9100` and `elizabeth.lan:9100` (both `up=1`, alongside the five
Talos nodes) — and that is the whole of it. **Everything below is host- or container-level state
that no query can currently answer.**

This is not theoretical. doco-cd froze on donkey for **six days** and crash-looped on navi
**6,416 times**, and both were found only by reading container logs by hand during an unrelated
audit. Every dashboard was green throughout, because nothing was looking.

- [ ] **navi has no `node-exporter` at all** — it runs only `matchbox` and `doco-cd-navi`, so CPU,
      memory, disk and uptime are invisible on the host that serves **PXE**. Nothing would report
      it filling its disk until a rebuild failed. Install it and add `navi.lan:9100` to the
      existing ScrapeConfig
- [ ] **No container-level metrics on any of the three** — cAdvisor or equivalent. Container
      up/down, restart counts and per-container resource use are all unobserved. A restart-rate
      alert alone would have caught navi in minutes instead of 4.5 days
- [ ] **Scrape doco-cd itself.** It logs `serving prometheus metrics` and serves an endpoint, but
      `docker/doco-cd/docker-compose.yaml` publishes **no ports**, so nothing can reach it. Publish
      it on all three hosts and scrape it
- [ ] **Alert on GitOps staleness, not just process liveness.** doco-cd reported `Up (healthy)`
      through the entire six-day freeze — the container was alive, the *sync* was dead. The useful
      signal is time-since-successful-poll and the deployed commit falling behind `main`; Flux has
      `Kustomization` readiness for exactly this and the Docker side has no equivalent
- [x] **Alert on node disk headroom — done 2026-08-12**, and the root cause was fixed rather
      than just alerted on. `NodeVarSpaceLow` warns at 20% free on `/var`, ahead of kubelet's
      15% eviction line; the built-in `KubeNodePressure` only fires once `DiskPressure` is
      already set, i.e. after pods start dying. Paired with
      `terminated-pod-gc-threshold: "30"`, since the real consumer was never images: dead pods
      pin containerd snapshots that image GC cannot reclaim. Full write-up under phase 2.

### Phase 6 — \*arr stack

Torrent only, no usenet. `tqm` already runs as an hourly cronjob.

- [ ] ⚠️ **Revise the Prowlarr indexers — half of them do not work.** Measured 2026-08-23 against
      the Prowlarr API, not assumed. `IndexerNoDefinitionCheck` reports an **error**:
      **HDT-LaFenice, MIRCrew and ilDraGoNeRo have no definition and will not work** — they must be
      removed and re-added. Two had been failing for months unnoticed: HDT-LaFenice since
      **2025-06-27** (14 months) and ilDraGoNeRo since 2026-02-17. Only **Girotorrent, Il Corsaro
      Blu and ItaTorrents** actually function. Nzb.su is a disabled usenet leftover in a
      torrent-only house.
      Same pass: remove the dead **Readarr** application connection, unavailable >6h and pointing at
      a project archived upstream; and Prowlarr is behind at v2.6.1.5509.
  - ⚠️ **Nothing alerts on any of this.** Prowlarr's `/api/v1/health` knew for over a year and the
    cluster does not scrape it, so a dead indexer is indistinguishable from a working one with
    nothing to return — the same failure shape as the inert alert rules. Worth a gatus or
    Prometheus check on that endpoint as part of the fix, otherwise the next silent death is found
    the same way: by accident.
  - Consequence for the comics library: only 3 working indexers map `7030:Books/Comics`
    (Girotorrent, Il Corsaro Blu, ItaTorrents), all Italian, so the torrent path delivers fumetti.
    See `docs/superpowers/specs/2026-08-23-comics-manga-library-design.md`.

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

- [x] ~~NFS canary reliability — Unraid disrupts NFS connections when the mover runs, canary doesn't handle it well~~
      **Moot: nfs-canary was retired in phase 1.5.** Replaced by `nfs-stale-exporter`, running on all
      five nodes, which probes the mount **root** and drives KEDA directly
- [ ] Scrape MinIO metrics from elizabeth into Prometheus — currently zero MinIO metrics exist, so restarts, latency and S3 error rates are invisible from the cluster. This is what forced the weekly CNPG backup failures to be diagnosed by hand-querying VictoriaLogs for `IncompleteBody` instead of a single query
- [ ] Enable syslog mirroring on elizabeth **to a share, not to flash** — the 5 parity sync errors of 2026-08-02 could not be investigated per-sector because syslog had already rotated and nothing is persisted. Without this, the next array incident is equally unexplainable
- [ ] Plan replacement of the parity disk `sdf` (WD100EFAX) — 57,077 power-on hours (~6.5 years), 1 ATA error logged, recorded max temp 60 °C. SMART still PASSED and it was not implicated in the sync errors, but it is by far the oldest device in the array (the two data disks are at 12,009h)

### Phase 10 — cleanup

The bin for deferred cleanup: things that are safe to remove but not yet worth the risk, and
leftovers that outlived whatever created them. Nothing here is urgent by construction — if an
item becomes urgent it belongs in a real phase. Add to this list rather than leaving debris
undocumented in another phase.

**Storage to reclaim**

- [ ] **Delete the old VolSync backup data on elizabeth — 35G.** `/mnt/user/backups/volsync`
      (18G, last write 2026-08-19) and `/mnt/user/backups/volsync-preblackout-20260818` (17G).
      The `nas-volsync` ClusterRepository was removed from git on 2026-08-24, so nothing in the
      cluster reads them; they are kept only as a cold second copy of the pre-kopiur era.
      **Deleting them is irreversible** — the phase 3 restores are the proof they are no longer
      needed, so this is a confidence question, not a technical one
- [ ] **Delete the ~100 GB of MinIO data** at `/mnt/disk2/atlantic_minio` on elizabeth (config at
      `/mnt/user/appdata/minio`). Phase 2.7 retired MinIO on 2026-08-25 — ObjectStores pruned,
      container stopped and removed, autostart entry gone — and deliberately kept the data.
      Nothing reads it: there is no MinIO endpoint any more, so using it would mean recreating the
      container from its Unraid template on `/boot`, which is left in place for exactly that.
      Delete when the garage history is long enough that pre-garage backups are no longer worth
      keeping

**Repo leftovers**

- [ ] **Delete `docker/donkey/power-nap-over/config.yaml`.** It is an auto-generated artifact
      that was committed by mistake and is **not mounted by anything** — `docker-compose.yaml`
      mounts the `power-nap-over-config` named volume, which the init container fills from
      `infra/data/networks.yaml` and `kubernetes/talos/talconfig.yaml`. The committed copy still
      carries `192.168.1.x` addresses from before the network migration, so it actively misleads
      anyone who reads it as configuration
- [ ] **Delete the orphan `/mnt/homelab/power-nap-over/config.yaml` on donkey** — same stale
      `192.168.1.x` content, also not mounted by the container

**Cluster objects**

- [ ] **Delete the `authelia-ext-auth` ReferenceGrant** (`kubernetes/apps/security/authelia/app/referencegrant.yaml`).
      Vestigial: it only authorised cross-namespace `backendRefs` to the authelia Service, which
      the `oidc-auth` component no longer sets. Proven 2026-07-30 — kopia lives in
      `volsync-system`, is not in the grant, and attaches fine
