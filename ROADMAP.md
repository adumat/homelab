# Homelab Roadmap

## Roadmap

Phases in order. Each gets an execution plan under `docs/superpowers/plans/` **when you
reach it**, not before: that way every plan is written against the real state of the repo
rather than the state predicted weeks earlier.

The half-numbered phases were inserted as work revealed them — 1.5 by a recurring failure,
2.5 because a 19-app migration should not be planned before a single volume has been
restored.

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

- [ ] kopiur operator plus a `ClusterRepository` on a **fresh** NFS path,
      `elizabeth.lan:/mnt/user/backups/kopiur`. VolSync keeps running against its own
      17 GiB repository throughout; elizabeth has 5.7 TiB free
- [ ] `components/kopiur` mirroring `components/persistence`, so an app switches by
      changing one line
- [ ] Migrate **prowlarr** only (1 GiB, config only, trivially rebuildable)
- [x] **Prove the restore, not the backup:** restore a snapshot into a fresh PVC through the
      `Restore` populator and diff it against the source. A backup never restored is a hope.
      **Done 2026-08-12: `diff -r` exit 0, 741 files, hash identical to the pre-migration
      volume.** Snapshot 111 s, restore+bind 34 s, repository 3.3 MB
- [ ] **Settle how phase 2.5 moves data, here rather than there** — phase 2 must exit with
      this answered, because discovering it mid-migration is too late. Both repositories are
      kopia, so kopiur may be able to restore straight from VolSync's existing backups,
      removing data copying from the migration entirely. Measured on the pilot, the
      identities differ in two places, both with fields that address them:

      | | VolSync writes | kopiur wrote | candidate fix |
      |---|---|---|---|
      | hostname | `downloads` | `downloads` | already matches (`hostnameExpr: namespace`) |
      | username | `prowlarr` | `downloads-prowlarr` | `usernameExpr: policyName` |
      | path | `/data` | `/pvc/prowlarr` | `sources[].sourcePathOverride: /data` |

      Test it against a second `ClusterRepository` with **`mode: ReadOnly`** — it "serves
      restores only", so VolSync's live repository cannot be mutated. Verify against
      `prowlarr-rescue`, which holds the frozen pre-migration state that VolSync backed up
      at 00:15 on 2026-08-12.

      Exit with one of: *adoption works* (2.5 is a one-line change per app),
      *adoption fails* (2.5 uses [pv-migrate](https://github.com/utkuozdemir/pv-migrate),
      never `kubectl cp` — see [AGENTS.md](AGENTS.md)), or *inconclusive with the reason*.
- [ ] Then miroir on a **loopfile** on the `local-hostpath` volume — no repartitioning, no
      spare disk, nothing taken from Ceph
- [ ] Verify `miroir-local` and `miroir-replicated` provision, snapshot and restore, and
      that a replicated volume survives rebooting the node holding its primary leg
- [ ] Measure miroir's RAM against Ceph's, then **write the decision down**

**OpenEBS stays.** The roadmap's reason for replacing it was snapshots, and nothing on
local storage needs them: none of the 13 PVCs has a ReplicationSource, and none should —
CNPG backs itself up, Ceph mons keep their own quorum, and the rest are caches.

**Why miroir matters here.** The goal is removing Ceph, which looks oversized: **45 GiB
stored** on 2.7 TiB with 3× replication, costing **~5.2 GiB of RAM** on 13 GiB nodes that
have already failed to schedule immich. CephFS holds 451 KiB and zero PVCs; there is no
object store; RWX comes from NFS. The capability that normally blocks leaving Ceph does not
apply.

**Three caveats on the miroir result:** a loopfile cannot prove production performance —
that needs the NVMe disks Ceph owns; durability drops from three replicas to two; and the
real risk is maturity, not capability, since miroir is pre-1.0 and would become primary
storage.

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

- [ ] Migrate the remaining 18 apps to kopiur, in batches, not in bulk
- [ ] Delete each app's orphaned `ReplicationDestination` by hand — Flux will not prune it
- [ ] Retire VolSync and its `perfectra1n` fork once all 19 are stable
- [ ] Keep the old repository as a cold fallback; do not delete it with VolSync
- [ ] Delete the leftover pre-migration rescue PVCs, `prowlarr-rescue` included — they are
      deliberately kept through this phase as known-good references
- [ ] If miroir won phase 2, replacing Ceph is a **separate** phase again — a storage
      migration does not belong inside a backup migration

Write this phase only once phase 2 has produced: snapshot and restore durations for a real
volume, repository growth rate, observed NFS load during a kopiur run, and whatever broke.

### Phase 3 — `just merge` and the gpu component

- [ ] Add the `just merge <digest|patch|minor|major>` recipe: bulk-merge Renovate PRs by
      label, skipping the ones labelled `hold`
- [ ] Factor the `ResourceClaimTemplate` of frigate and jellyfin into a `components/gpu`.
      **This is not a new capability**: DRA (`resource.k8s.io/v1`) is already in use in both
      apps. The gain is removing the duplication
- [ ] While factoring, check whether `adminAccess: true` and `allocationMode: All` are
      needed — neither is set today

### Phase 4 — the missing observability

Hardware already in the house, metrics absent.

- [ ] `kromgo` — PromQL-driven badges on `envoy-external`, with the badges in the README.
      The domain is not treated as a secret: manifests still use `${DOMAIN}`, but for a
      single source in `cluster-secrets`, not for confidentiality
- [ ] `snmp-exporter` — HPE OfficeConnect 1820 switch and the UPS, invisible today
- [ ] `drm-exporter` — Intel GPU utilisation, invisible today even though frigate and
      jellyfin transcode on it
- [ ] Evaluate NUT **in cluster**: today the server runs on donkey under Docker and only
      the exporter runs in the cluster
- [ ] Pick up the MinIO metrics scrape from elizabeth (see Follow-ups): it is the same gap,
      and it is what forced the CNPG failures to be diagnosed by hand-querying VictoriaLogs
- [ ] Alert on node disk headroom. On 2026-08-08 kube-nuc crossed the eviction threshold,
      took a `disk-pressure` taint, and the descheduler evicted 31 pods — the first sign
      was an unrelated CI job failing. Kubelet image GC recovered it unaided (the tuning in
      `machine-kubelet.yaml` did its job), but steady state is 66–72% used with images the
      dominant consumer, so a Talos image storm plus a Renovate burst can repeat it

### Phase 5 — \*arr stack

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
