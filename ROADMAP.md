# Homelab Roadmap

## Roadmap

Five phases, in order. Each gets an execution plan under `docs/superpowers/plans/`
**when you reach it**, not before: that way every plan is written against the real state
of the repo rather than the state predicted weeks earlier.

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

### Phase 1.5 — NFS stale handles: fix them, stop living with them

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

### Phase 2 — miroir, then kopiur

The riskiest phase. **Mandatory order: storage first, backup second.**

Current state: 12 volumes on `ceph-block`, 7 on `openebs-hostpath` (immich, jellyfin, the
CNPG clusters), 18 apps protected by VolSync.

- [ ] Install miroir (`miroir-system`) and create the `miroir-local` and
      `miroir-replicated` storage classes
- [ ] Migrate **one non-critical volume** from `openebs-hostpath` to `miroir-local` to
      validate the mechanism end to end before depending on it
- [ ] Migrate the remaining `openebs-hostpath` volumes to `miroir-local` and remove OpenEBS
- [ ] Install kopiur with the mover cache on `miroir-local` and migrate backups
      **app by app**, not in bulk
- [ ] Retire VolSync only once all 18 apps are stable on kopiur
- [ ] **Separate phase, to be measured:** move a subset of apps from `ceph-block` to
      `miroir-replicated` and compare memory usage and latency, to decide with data whether
      Ceph is oversized for three M720Q. This is not a decided migration, it is an
      experiment

**Two explicit risks, not to be treated as footnotes:**

1. **kopiur is `v1alpha1` and moves fast.** Six releases in three weeks (0.8.0 → 0.9.3).
   The project's documentation lists CRDs — `BackupConfig`, `Backup`, `BackupSchedule`,
   `Maintenance` — **different** from the ones in use in 0.9.3 (`SnapshotPolicy`,
   `SnapshotSchedule`). Moving 18 apps onto it means budgeting for a rename migration soon
2. **Restoring into a storage class different from the source is undocumented.** It would
   be the elegant mechanism for moving openebs→miroir, but it must be verified on a single
   volume before the migration is built on top of it

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
