# Docs consolidation — design

Status: design, awaiting review (2026-11-10)

## Problem

Knowledge about this homelab is spread across four places that overlap and drift:

| Place | Holds | Failure |
|---|---|---|
| `ROADMAP.md` (~2,900 lines) | backlog, incident diary, decisions, documentation | last edited 2026-09-09; open and closed items are indistinguishable |
| `AGENTS.md` | agent traps, runbooks | works, but runbooks for humans crowd it |
| `docs/superpowers/` (28 plans, 29 specs) | designs and execution plans | gitignored: exists on one laptop only; checkboxes never ticked |
| `openspec/` | one change (deploy-ippopeto) | never committed |

Sub-projects (peekaboo, miroir, paradox-dgp-mqtt, nfs-stale-exporter, chat-archive) each
keep whatever they keep, with no shared view of what is open.

The root cause is not the format. Updating the record was always a separate step after the
work, so it did not happen.

## Goals

1. Answer two questions without archaeology: *how does X work and why*, and *what is open*.
2. Keep the record current as a side effect of committing, not as a separate chore.
3. Plain Markdown in git, so no tool's lifespan decides the content's lifespan.
4. Browse everything — every repo's docs plus private notes — in one Obsidian vault on the
   Mac, an iPhone and an Android phone, synced through self-hosted infrastructure.
5. Personal material (paper archive, family deadlines) never enters a public repo.

## Non-goals

- A spec framework (OpenSpec, Spec Kit, Kiro). Homelab drops OpenSpec; ippopeto keeps its
  own, which is that repo's choice.
- An external task manager (GitHub Issues, Asana, Jira) or wiki (Confluence).
- Converting every old superpowers file. They are sources to distil, then archived as-is.
- Editing repo docs from a phone.

## Design

### 1. Per-repo documentation

Every repo owns a `docs/` folder, versioned with its code:

```
docs/
├── <area>.md          # how it works today, how to operate it, links to ADRs
├── adr/NNNN-<slug>.md # one decision each; never rewritten, only superseded
├── backlog.md         # open items as `- [ ]` lines with tags
├── plans/             # designs and plans for large work
│   └── done/          # finished plans, kept for reference
└── map.yaml           # path globs → area page (homelab; other repos when useful)
```

- **Area pages** are prose, written from the repo's *current* state. Homelab areas, about
  twelve: cluster and Talos, networking, auth, storage, backup, NFS and elizabeth,
  observability, GitOps and CI, Docker hosts, power and UPS, home automation, media.
- **ADRs** use a short MADR shape: context, decision, consequences, status, date. A changed
  decision gets a new ADR that marks the old one `superseded by`.
- **Backlog lines** carry tags for filtering: `#fisico` (needs hands on hardware),
  `#decisione` (needs the owner to decide), `#bloccato` (waiting on something named in the
  line). Personal items never go here.
- **Links** are relative Markdown links, never `[[wikilinks]]`, so they resolve on GitHub
  and in Obsidian alike.
- **AGENTS.md** keeps the traps. Long procedures move to the area page they belong to
  (consistent with open PR #670). AGENTS.md gains the rule: update the area page in the
  same commit; a new decision becomes an ADR; closing a backlog item removes its line in
  the commit that does the work.

### 2. Enforcement: a commit-msg hook

A local `pre-commit` hook at the `commit-msg` stage reads `docs/map.yaml`:

```yaml
backup:
  page: docs/backup.md
  paths:
    - kubernetes/apps/volsync-system/**
    - kubernetes/components/kopiur/**
```

If the staged diff touches a mapped path and not that area's page, the commit fails and
names the page. A `Docs: n/a` trailer in the message passes it, for bumps and changes that
do not alter behaviour. Commits authored by Renovate are exempt.

The `commit-msg` stage needs `pre-commit install --hook-type commit-msg`; the README's
setup step must say so, or the hook silently never runs.

### 3. The Obsidian vault

A new, dedicated vault (not the Claude chat-archive vault):

```
Homelab/                       # vault root
├── Cruscotto.md               # Tasks-plugin queries over every backlog + personal tasks
├── repos/<repo>/              # read-only mirror of each repo's docs/
├── Personale/                 # paper archive, deadlines, scan worklist — editable
└── Archivio/superpowers/      # the 57 old files, unchanged
```

**Mirror, not symlinks.** Obsidian's documentation strongly advises against symlinks and
says they do not work with any sync. Instead a script on the Mac copies each repo's
`docs/` into `repos/<repo>/` (`rsync --delete`). It runs from git `post-commit` and
`post-merge` hooks in each repo plus a periodic launchd job as a safety net. A note at the
top of `repos/` states that edits there are overwritten; docs are edited in the repos.

### 4. Sync: Self-hosted LiveSync

- `couchdb` app in the cluster (app-template, `miroir-replicated`, kopiur backup).
- **Internal only**: route on `envoy-internal`; phones sync on the home LAN or over VPN.
- The LiveSync plugin cannot do OIDC, so CouchDB's own auth guards it; LiveSync's
  end-to-end encryption is on, so the server holds ciphertext only.
- Mac, iPhone and Android run the plugin.
- Pilot check: mirror updates written while Obsidian on the Mac is closed must reach the
  phones once it opens. If they need Obsidian open, that delay is accepted.

### 5. What happens to the existing material

| Source | Destination |
|---|---|
| Completed plans and specs, ROADMAP narrative, AGENTS.md | distilled into area pages and ~12–15 retroactive ADRs, dated when each decision was taken |
| Open items in the 2026-11-09 audit (~40) | `docs/backlog.md` in the repo they belong to |
| Large open work: PNO v2, *arr health (phase 6a), climate, off-site backup copy, donkey emergency bastion, ps5-mqtt | one file each in `docs/plans/`, proposal only |
| Personal items (scan worklist, deadlines, archive findings) | vault `Personale/` |
| `docs/superpowers/` | vault `Archivio/superpowers/`, then removed from the repo tree (it was never tracked) |
| `ROADMAP.md` | shrunk to one page of priorities linking to plans; history stays in git |
| `openspec/` in homelab | deploy-ippopeto's open task (code rotation) moves to the backlog; folder removed |

Before every commit that ports content, check it for personal data: the repo is public.

## Rollout

One commit per step.

1. `docs/` skeleton, `map.yaml`, commit-msg hook, AGENTS.md rule.
2. **Pilot**: `docs/backup.md` and its ADRs; the vault with the homelab mirror; couchdb and
   LiveSync on one phone. Stop for the owner's review of format and sync before going on.
3. Remaining homelab area pages and ADRs.
4. Homelab `backlog.md` and the six plan proposals.
5. Minimal `docs/` with a backlog in peekaboo, miroir, paradox-dgp-mqtt,
   nfs-stale-exporter and chat-archive; add them to the mirror.
6. Shrink ROADMAP.md; move personal and superpowers files to the vault; remove `openspec/`.

## Risks

- **The hook gets bypassed** with `Docs: n/a` out of habit. Mitigation: the trailer shows
  in `git log`, so a periodic grep shows whether it is being overused.
- **LiveSync and external writes.** The mirror writes files outside Obsidian; the pilot
  proves whether LiveSync picks them up.
- **CouchDB on the LAN only** means no sync away from home without VPN, accepted by the
  owner.
- **Distillation errors.** Area pages are written from the repo's state, not from old plans;
  where they disagree, the repo wins.
