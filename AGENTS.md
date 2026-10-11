# AGENTS.md

Guide for agents working on this repo. Read it before changing anything.

Every claim here has been verified against the repo or the cluster. If you find one that
is false, fix it: a wrong trap in this file misleads every future agent.

---

## What this repo is

An IaC monorepo for a homelab. Not just Kubernetes: it also manages the router, Docker
containers on three hosts, and a few home-grown applications.

| Layer | Technology |
|---|---|
| Node OS | Talos Linux v1.14.1, config rendered by minijinja + `talosctl machineconfig patch` |
| Kubernetes | v1.36.3 |
| GitOps | Flux v2 (flux-operator + flux-instance) |
| CNI | Cilium — BGP, native routing, kube-proxy replacement, DSR + maglev |
| Ingress | Envoy Gateway (Gateway API). **Never `Ingress`** |
| Storage | miroir (DRBD9) — `miroir-replicated` default (replicas 2 + diskless tie-breaker), `miroir-local` node-pinned |
| Backup | VolSync + Kopia |
| Databases | CloudNative-PG, Dragonfly |
| Auth | Authelia + LLDAP, OIDC through Envoy `SecurityPolicy` |
| Secrets | Bitwarden Secrets Manager + External Secrets Operator |
| Charts | bjw-s `app-template` 5.0.1, via `chartRef` → shared `OCIRepository` |
| Router and hypervisor | OpenTofu against OPNsense and Proxmox |
| Docker on hosts | doco-cd (GitOps for compose) on donkey, elizabeth, navi |

### Cluster

Five nodes, all amd64.

| Node | IP | Role |
|---|---|---|
| bulbasaur | 10.1.10.10 | control plane |
| charmander | 10.1.10.11 | control plane |
| squirtle | 10.1.10.12 | control plane |
| magikarp | 10.1.10.21 | worker |
| snorlax | 10.1.10.23 | worker |

Pod CIDR `10.42.0.0/16`, service CIDR `10.43.0.0/16`.

---

## Layout

```
kubernetes/
├── flux/cluster/ks.yaml     # Flux entrypoint → ./kubernetes/apps
├── components/              # reusable Kustomize Components
├── apps/<namespace>/<app>/  # ks.yaml + app/
├── bootstrap/               # helmfile for initial bootstrap
└── talos/                   # node inventory, machineconfig template, patches
infra/                       # OpenTofu: OPNsense + Proxmox
docker/                      # doco-cd and per-host compose stacks
services/                    # home-grown applications (built in CI)
scripts/                     # shared shell utilities
docs/superpowers/            # specs and plans (NOT tracked in git)
```

The 15 namespaces under `kubernetes/apps/` are discovered by Flux **automatically**: there
is no parent `kustomization.yaml` in `kubernetes/apps/` to update when you add one. Just
create the directory with its own `kustomization.yaml`.

---

## Adding an application

Minimum structure:

```
kubernetes/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml     # only if the chart is not app-template
    ├── helmrelease.yaml
    └── externalsecret.yaml    # only if secrets are needed
```

Then add `./<app>/ks.yaml` to the `resources` list in the namespace's
`kustomization.yaml`.

**Before inventing structure, copy a recent app.** Useful references:

| App | Shows |
|---|---|
| `services/it-tools` | minimal app with a route and OIDC |
| `services/paperless` | secrets, CNPG, config files |
| `home/frigate` | GPU via DRA, persistence, NFS |
| `observability/silence-operator` | non-app-template chart with its own `OCIRepository` |

### `ks.yaml`

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app>
  namespace: &namespace <namespace>
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  components:                      # only the ones actually needed
    - ../../../../components/persistence
  dependsOn:
    - name: miroir-config
      namespace: miroir-system
  interval: 1h
  path: ./kubernetes/apps/<namespace>/<app>/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
    substitute:
      APP: *app
  prune: true
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: *namespace
  timeout: 5m
  wait: false
```

### Variables from `cluster-secrets`

Available in every Kustomization that does `substituteFrom`:

`DOMAIN` · `LOCAL_DOMAIN` · `CLOUDFLARE_TUNNEL_ID` · `EMAIL_ADDRESS_1` ·
`SECRET_BITWARDEN_ORGANIZATION_ID` · `SECRET_BITWARDEN_PROJECT_ID` · `SECRET_NAS_NAME`

---

## Components

Four, under `kubernetes/components/`. Added to `spec.components` in a `ks.yaml`.

| Component | Consumers | Purpose |
|---|---|---|
| `common` | 15 (in namespace `kustomization.yaml` files, not in `ks.yaml`) | creates the Namespace, Flux alerts, the app-template `OCIRepository`, the SOPS secret |
| `persistence` | 18 | PVC + VolSync `ReplicationSource`/`Destination` |
| `oidc-auth` | 14 | OIDC `SecurityPolicy` + the client's `ExternalSecret` |
| `nfs-scaler` | 8 | KEDA `ScaledObject` that scales apps to zero when NFS is unhealthy |

`common` is a special case: it lives in the namespace's `kustomization.yaml`, and the
`Namespace` it contains has `name: _`, renamed by the parent kustomization's `namespace:`
transformer. Do not "fix" it thinking it is a mistake.

---

## Networking

**No `Ingress`.** Gateway API only.

| Gateway | Namespace | Use |
|---|---|---|
| `envoy-internal` | `network` | LAN and VPN only |
| `envoy-external` | `network` | public, behind Cloudflare Tunnel |

The certificate is a **wildcard** (`${DOMAIN}` + `*.${DOMAIN}`), so adding a hostname does
not show up in Certificate Transparency logs.

Route inside an app-template HelmRelease:

```yaml
    route:
      app:
        hostnames:
          - "{{ .Release.Name }}.${DOMAIN}"
        parentRefs:
          - name: envoy-internal
            namespace: network
            sectionName: https
```

---

## Secrets: Bitwarden + External Secrets

No plaintext secrets in the repo. Four SOPS files exist purely for bootstrap
(cluster-secrets, flux-instance, cert-manager, the ESO store): **everything else goes
through Bitwarden Secrets Manager**.

### The non-obvious part: values are JSON

In Bitwarden Secrets Manager a secret is **a single key/value pair**. The multiple fields
that `ExternalSecret`s consume exist because the *value* is a JSON object, which
`dataFrom: extract` decomposes.

Real example: the secret `mqtt-frigate-secret` has the value
`{"username": "...", "password": "..."}`, and the ExternalSecret does:

```yaml
  target:
    name: frigate-secrets
    template:
      data:
        FRIGATE_MQTT_USER: '{{ .username }}'
        FRIGATE_MQTT_PASSWORD: '{{ .password }}'
  dataFrom:
    - extract:
        key: mqtt-frigate-secret
```

If the value is not valid JSON, `extract` yields no fields and the ExternalSecret sits in
error without saying why.

### Creating a secret with `bws`

The project is **Clusterone**, id `cd618c62-cbca-490a-85d0-b3dd01178520`. The token lives
in `.env` as `BWS_ACCESS_TOKEN`.

```bash
PROJECT=cd618c62-cbca-490a-85d0-b3dd01178520

# single-field value
mise exec -- bws secret create <name> "$(jq -nc --arg v "$VALUE" '{KEY:$v}')" "$PROJECT"

# multiple fields, with a multi-line file (PEM, kubeconfig, keys)
mise exec -- bws secret create <name> "$(jq -nc \
  --arg id "$CLIENT_ID" \
  --rawfile key ./key.pem \
  '{CLIENT_ID:$id, PRIVATE_KEY:$key}')" "$PROJECT"
```

**Always** build the JSON with `jq -nc` and pull multi-line files in with `--rawfile`:
pasting a PEM by hand breaks the newlines and produces invalid JSON.

### Inspecting without printing values

```bash
PROJECT=cd618c62-cbca-490a-85d0-b3dd01178520
id=$(mise exec -- bws secret list "$PROJECT" | jq -r '.[] | select(.key=="<name>") | .id')
mise exec -- bws secret get "$id" | jq -r '.value | (fromjson? // empty) | keys[]'
```

Prints field names only. An empty response means the value is not JSON.

**Never print a secret value to the terminal** unless strictly necessary: it ends up in
the session transcript.

---

## Comments

A comment explains a decision the YAML cannot. Nothing else.

Write one only for a **non-obvious constraint that outlives the change**: an upstream bug
being worked around, a value that looks wrong but is deliberate, a port that must avoid
another service. Name the constraint, not the story. The comments in Authelia's
`helmrelease.yaml` and in `components/oidc-auth/` are the right kind: without them, those
choices look like mistakes.

Never write:

- **Restatements.** If deleting the comment loses nothing, it should not have been written
- **Migration narration.** Steps, "now that X", "replacing Y", what the value used to be.
  Procedures belong in the commit message, which is where someone looks to understand *why
  this changed*. A comment describing a one-off procedure ages into a lie
- **Session or reasoning leakage.** Notes to self, what was tried, what an agent concluded.
  Git history holds this

---

## Commits

**One commit carries one semantic change.** If the subject needs "and", or the body
explains two unrelated things, it is two commits. A HelmRelease change and an edit to this
file are never the same commit, however close together they happened.

**Stage deliberately:** `git add <specific paths>`, never `git add -A` or `git add .`.
Only the files belonging to the change, even when other edits are sitting in the tree —
they may be work in progress.

Split before committing, not after: once pushed, fixing it means rewriting published
history.

---

## Flux reconciles on push

There is an active GitHub `Receiver` (`flux-system/github-webhook`): Flux reconciles
**immediately** on push, not on the interval. Never tell the user to "wait X minutes for
Flux to reconcile".

To force it anyway:

```bash
mise exec -- flux reconcile ks <name> -n <namespace> --with-source
```

---

## Validation

```bash
mise exec -- pre-commit run --files <file...>   # the same hooks that run on commit
mise exec -- flate test all --path ./kubernetes/flux/cluster
mise exec -- flate diff all --path ./kubernetes/flux/cluster
mise exec -- kubectl ...                        # always through mise exec
```

`flate` replaced `flux-local`, which upstream archived. PR validation itself no longer
runs in GitHub Actions at all: konflate does it from inside the cluster. `flate` stays as
the CLI, used locally and by the `image-pull` workflow.

It is stricter than `flux-local` about values a chart does not consume, so expect warnings
on manifests that passed before. Warnings do not fail the run; a non-zero exit does.

`kubeconform` runs in pre-commit over `kubernetes/**.yaml` and **excludes**
`kustomization.yaml`, `secret.sops.yaml`, `talconfig.yaml`, `talenv.yaml`,
`talos/patches/`, `/dashboards/`, `/resources/`, `bootstrap/helmfile.d/`.

Available `just` recipes: `check-nodes`, `mount`/`unmount`/`mounts`, plus the `bootstrap`,
`kube` and `talos` modules.

---

## Conventions

1. **Every tool goes through `mise exec --`** — `kubectl`, `flux`, `talosctl`, `bws`, `jq`
2. **Schema header** `# yaml-language-server: $schema=...` on every YAML. The repo is not
   uniform about the source: `kubernetes-schemas.pages.dev` and `json.schemastore.org`
   dominate; for new resources use the same source as neighbouring files
3. **`chartRef` + `OCIRepository`**, never inline `chart:`
4. **Images pinned** by tag; with digest where one is already present
5. **`TZ: Europe/Rome`** in container env
6. **The domain is always written as `${DOMAIN}`**, never in plaintext. It is not a secret
   — the repo is public and the exposed apps have public DNS records — but `cluster-secrets`
   stays the single source, so changing domain costs one edit instead of a repo-wide `sed`.
   Same for `${LOCAL_DOMAIN}`
7. **Conventional commits**, no `Co-Authored-By`
8. **Small changes go straight to `main`**, no branch
9. Non-Kubernetes YAML (application config) goes under `resources/` with a `.yaml`
   extension: that is exactly why those paths are excluded from kubeconform. Do not rename
   them

---

## Runbooks

Incident procedures live in [`docs/runbooks/`](docs/runbooks/), one per file. **When a
symptom below matches, read that runbook before acting**: several of them exist because the
obvious fix is wrong, and some make things worse.

| Symptom | Runbook |
|---|---|
| A node is hung hard: no ICMP, no Talos API, no answer to WOL | [rack-power-cycle](infra/docs/rack-power-cycle.md) |
| Pods stuck `Terminating`, apps that see no files, `fileid changed`, `NfsMountStale`, `KubeJobFailed` on `qbittorrent-tools` | [nfs-stale-handles](docs/runbooks/nfs-stale-handles.md) |
| Many MiroirVolumes `Degraded` on one node; `drbdadm` exits 10 with `conflicting use of device-minor` | [drbd-duplicate-minor](docs/runbooks/drbd-duplicate-minor.md) |
| One volume: `MiroirVolumeOutOfSync`, a peer stuck at `Connecting`, a miroir agent pod stuck `Terminating`; `drbdsetup` in state `D` | [drbd-hung-drbdsetup](docs/runbooks/drbd-hung-drbdsetup.md) |
| A node back from reboot tainted `DiskPressure`; a tuppr rollout parks partway | [node-false-diskpressure](docs/runbooks/node-false-diskpressure.md) |
| Adding a Talos system extension; a tuppr upgrade refusing on a schematic mismatch | [talos-extension-rollout](docs/runbooks/talos-extension-rollout.md) |
| Every backup on a repository failing `decrypt blob: ciphertext too short` | [kopia-zero-length-blobs](docs/runbooks/kopia-zero-length-blobs.md) |
| A kopiur snapshot failing `PermissionDenied`; choosing a mover UID | [kopiur-mover-uid](docs/runbooks/kopiur-mover-uid.md) |
| A Kustomization stuck `Ready=Unknown` on a `Restore` reported `InProgress` | [flux-wait-kopiur-restore](docs/runbooks/flux-wait-kopiur-restore.md) |
| Moving an app between VolSync and kopiur; `spec is immutable after creation` on its PVC | [kopiur-vs-volsync](docs/runbooks/kopiur-vs-volsync.md) |
| Recreating a PVC from a backup, or migrating one to another backend | [pvc-migration](docs/runbooks/pvc-migration.md) |
| Removing an app, or finding its backups afterwards | [deleting-an-app](docs/runbooks/deleting-an-app.md) |
| ARC listener crash-looping on `ephemeralrunnersets ... not found` | [arc-listener-stale-runnerset](docs/runbooks/arc-listener-stale-runnerset.md) |
| Changing ESPHome device config, or a config change that does nothing | [esphome](docs/runbooks/esphome.md) |

---

## Traps

All verified. These are things you cannot deduce by reading the code. The longer ones,
with procedures, are the runbooks above.

### Envoy's refresh cookie must not outlive Authelia's refresh token

`components/oidc-auth` sets `defaultRefreshTokenTTL: 168h`, so Envoy keeps a refresh cookie for a
week and replays it until it expires. Authelia's **default** `refresh_token` lifespan is **1h30m**.
When the token dies first, Envoy retries the refresh in a loop instead of restarting the login flow,
and those retries trip Authelia's per-IP rate limiter on `/api/oidc/token`.

**The symptom does not point at the cause.** One app's login fails while the gateway still returns a
correct `302` with the right `client_id`, `redirect_uri` and PKCE challenge — because the break is in
the *token exchange*, which the rate limiter is rejecting for every app behind that Envoy replica.
The evidence is in Authelia's log, not Envoy's:

```
Refresh Token expired at '<time>'          # replayed for hours
Rate Limit Exceeded  path=/api/oidc/token  # backoff grows past 500s
```

⚠️ **`rollout restart deploy/envoy-internal` does NOT fix this.** The stuck state is the *client's
cookie*, so a fresh replica reads the same cookie and replays the same dead token. The cookie has to
be cleared in the browser (a private window proves it immediately).

Every Envoy-OIDC client therefore carries `lifespan: 'envoy_session'` (`refresh_token: '2 weeks'`),
which clears the 168h TTL with margin. Keep that invariant when adding a client: a new
`oidc-auth` consumer with no `lifespan` inherits 1h30m and reintroduces the loop. `peekaboo` uses
`long_session` (3 months) instead, for a page left open for hours.

### Flux substitutes an unset variable with the empty string

Not an error — a silently invalid resource. The live case is `oidc-auth`:
`components/oidc-auth/authentication.yaml` uses `name: ${OIDC_ROUTE}` **with no default**,
and every consumer must set both `APP` and `OIDC_ROUTE`. Forget the second and you get a
`SecurityPolicy` with `targetRefs[0].name: ""` and no message at all.

`APP` is the identity (client_id, Bitwarden item, policy name); `OIDC_ROUTE` is the
HTTPRoute to attach to. They usually match, but not for chart-generated routes
(`kube-prometheus-stack-alertmanager`, `victoria-logs-server`) nor
for `home-assistant-code`.

### `${VAR:=default}` cannot be used in pattern-validated fields

The kubeconform hook runs in pre-commit, **before** Flux substitutes: a `${...}` in a field
with a CRD pattern fails validation. For per-app overrides use a kustomize patch — see
`kubernetes/apps/home/peekaboo/app/kustomization.yaml`, which patches
`/spec/oidc/defaultRefreshTokenTTL`.

### Authelia: three things that kill it silently

All three are in its `helmrelease.yaml`, with comments explaining why.

- **`enableServiceLinks: false` is mandatory.** Without it Kubernetes injects
  `AUTHELIA_PORT`, which Authelia reads as the deprecated `port` setting, conflicts with
  `server.address`, and it refuses to start with an opaque error.
- **No `readOnlyRootFilesystem`.** It fails the startup checks with no useful logs.
- **`strategy: RollingUpdate` with `unavailable: "0"` and `surge: 1`.** Two pitfalls in
  one: in app-template the keys are `unavailable`/`surge`, not `maxUnavailable`/`maxSurge`;
  and the `0` **must** be quoted, because unquoted it is falsy in Go templates, so the
  chart drops it and Kubernetes applies the default 25%.

Always validate the config before pushing:

```bash
mise exec -- kubectl exec -n security deploy/authelia -- \
  sh -c 'X_AUTHELIA_CONFIG_FILTERS=template authelia config validate --config /config/configuration.yaml'
```

### A CiliumNetworkPolicy that selects nothing looks identical to one that works

`kubectl get cnp` shows the policy as present either way. There is no error, no event,
and no status saying "this selector matched zero endpoints".

Hit on 2026-08-08: the runner fence used `endpointSelector: {runner: homelab-runner}`,
copied from another repo. ARC actually labels its pods `app.kubernetes.io/component=runner`
and `actions-ephemeral-runner=True` — no `runner` label exists. The fence was decorative
for its whole first day.

Always verify a policy against a live pod, never against the manifest:

```bash
mise exec -- kubectl get pods -n <ns> --show-labels
# then, from inside a selected pod, prove a denied destination is actually denied
mise exec -- kubectl exec -n <ns> <pod> -- timeout 5 nc -z <denied-ip> 22; echo "exit=$?"
```

### `image-pull` pulls onto one node, and that is correct

The workflow runs `talosctl --nodes "$NODE" image pull`, where `NODE` is the IP of the node
the runner happened to land on. It looks broken — four other nodes get nothing — but
**spegel** is a cluster-local OCI mirror: seeding one node is enough, the rest fetch over
the LAN instead of from the internet. Without spegel the workflow would be close to
pointless.

### Never trust `kubectl cp` or `kubectl exec … | cat` for real data

Both silently truncate. Copying prowlarr's 741-file volume out: `kubectl cp` produced 243
files, an `exec … tar cf -` stream produced 620, and `exec … cat` of a verified 58,003,456
byte archive produced 56,594,427 bytes with a different SHA. None of them reported an
error.

To move volume data, stay inside the cluster: create a second PVC and copy pod-to-pod with
`cp -a`, then verify with a checksum manifest, not a file count:

```sh
cd /src && find . -type f | sort | xargs md5sum | md5sum
```

### konflate: two ways to think it works when it does not

`publicUrl` does **not** expose konflate or enable anything. It is used only to build the
link inside the status check it publishes; unset, the status is posted without a link.
Reachability comes from the HTTPRoute, which is on `envoy-external` precisely so GitHub can
deliver webhooks.

And the webhook is only half-configured until it also exists **on the GitHub side**
(Settings → Webhooks, payload URL `/hooks`, matching secret). With just the in-cluster
secret, konflate falls back to polling open PRs every 30 minutes and everything looks
fine — comments appear, status checks appear, only late. Confirm under Settings → Webhooks
→ Recent Deliveries that the response is **200**.

### Restarting `envoy-gateway` is not enough

After a change touching `SecurityPolicy` resources or the IdP, restarting only the control
plane leaves the data-plane replicas (`envoy-internal`, `envoy-external`) out of sync: one
holds good config, the other a cached discovery failure, and responses **alternate between
302 and 500 per request**. A single `curl` looks healthy. Sample repeatedly, and restart
the data plane too.

### Talos: config is rendered on demand, never stored

`just talos render-config <ip>` builds a node's config from `machineconfig.yaml.j2`
(inventory in `talconfig.yaml`, versions in `talenv.yaml`, secrets as `bws://` references),
then layers `patches/global` and, on control planes, `patches/controller` with
`talosctl machineconfig patch`. Nothing is written to disk, so there is no generated copy to
go stale. talhelper is gone: it was archived upstream and cannot render Talos 1.14.

Talos patches are **not** applied by Flux: they need `talosctl apply-config`. Before applying,
prove the change is the one you meant:

```sh
mise exec -- just talos render-config <ip> | mise exec -- talosctl -n <ip> apply-config --dry-run -f /dev/stdin
```

Then `just talos apply-node <ip>`, one node at a time. Feature-flag changes apply without a
reboot; `machine.files` changes do not.

**Control planes one at a time.** etcd has three members and quorum is two, so applying to
two at once risks it. Check `talosctl -n <ip> etcd status` between nodes.

### A system extension does not load its kernel module

`siderolabs/drbd` only *ships* `drbd.ko`. Nothing loads it, so
`talosctl get extensions` reports the extension present while `/proc/drbd` does not exist —
and miroir's agents then log `DRBD kernel module unavailable; running local-only`, which
leaves `miroir-local` working normally while `miroir-replicated` cannot work at all. Loading
lives in [machine-kernel.yaml](kubernetes/talos/patches/global/machine-kernel.yaml), and
`usermode_helper=disabled` is mandatory rather than tuning: the kernel side otherwise calls
`/sbin/drbdadm` on the host, which Talos does not have.

Modules load on `apply-config` — no new schematic and no reboot. The agents only probe at
startup, so `kubectl rollout restart ds/miroir-agent -n miroir-system` afterwards or they
stay in local-only mode.

### miroir shares host ports with host-network Ceph

`drbd.portBase` defaults to **7000**, which is Ceph's mgr dashboard. Rook here runs
`provider: host` and miroir's agents run hostNetwork, so they contend for the same node
ports. Ceph's range on this cluster is `ms_bind_port_min` 6800 to `ms_bind_port_max`
**7568** — check it rather than assuming the 7300 default — so miroir starts at **7700**,
one ascending port per replicated volume.

Two more miroir gotchas: `agent.loopfileBaseDirs` must repeat every `loopfile.baseDir`,
because the topology lives in CRs the chart cannot read at render time while the hostPath
mounts are pod spec; and a loopfile pool needs its `baseDir` to be reflink-capable (XFS
`reflink=1` or btrfs) or the agent refuses the pool outright.

### Testing that data survived a reboot: never use a Pod that can restart

A bare Pod defaults to `restartPolicy: Always`. If its command writes the fixture, a node
reboot restarts the container, which rewrites the data **and** any checksum file next to it.
That is worse than losing the baseline: an intact volume and a wiped one then look identical,
because a wiped volume gets refilled the same way.

Use `restartPolicy: Never`, make the write idempotent (`[ -f /d/checksum ] && exit 0`),
**delete the writer before the reboot** so nothing can touch the volume, and keep the
expected checksum outside the cluster.

### Talos API access from pods is allow-listed twice

A `talos.dev/v1alpha1 ServiceAccount` mints a talosconfig into a Secret, but only if
**both** the requesting namespace and the requested role appear in
`kubernetes/talos/patches/controller/talos-api-access.yaml`. Otherwise the CRD sits there
with `status.failureReason: Namespace is not allowed` and no Secret is ever created — no
event, no error anywhere else.

Verified 2026-08-08: **`os:reader` cannot `talosctl image pull`** (`PermissionDenied`);
`os:operator` is the weakest role that can.

The minted config uses `talos.default` as its endpoint, a cluster-internal service name.
Correct from a pod; from a laptop it needs `--endpoints <node-ip>`, or it fails with
`name resolver error: produced zero addresses`.

### etcd has three members

Verified: `bulbasaur`, `charmander` and `squirtle`, since phase 3 (2026-08-23). Quorum is 2,
so **one** control plane may be lost or rebooted; never take two down together.

### StorageClass parameters are immutable, and it blocks the whole Kustomization

Changing `parameters` on an existing StorageClass cannot be applied — Flux fails the dry-run
and the **entire Kustomization stops reconciling**, pinned on its last good revision, so
unrelated resources in it silently stop updating too:

```
StorageClass/miroir-replicated dry-run failed (Invalid): ... parameters: field is immutable
```

Delete and recreate it. That is safe when nothing references it — existing PVs keep the
parameters resolved at creation time, so a class can be replaced without touching live volumes.
Check first:

```sh
kubectl get pvc -A -o json | jq '[.items[]|select(.spec.storageClassName=="<class>")]|length'
```

## What not to do

- Do not use `Ingress` — `HTTPRoute` only
- Do not write the domain in plaintext: use `${DOMAIN}`
- Do not use inline `chart:` in HelmReleases
- Do not create an `OCIRepository` for app-template: the shared one is in `components/common`
- Do not hand-edit a node's config with `talosctl edit mc`: the next `apply-node` reverts it. Change the template or a patch
- Do not print secret values to the terminal
- Do not add a component to an app "just in case": each one creates real resources
