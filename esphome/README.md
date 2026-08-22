# ESPHome configuration

Device configuration lives here and is pulled by ESPHome at compile time using
[remote packages](https://esphome.io/components/packages.html). The dashboard in namespace `home`
still compiles, flashes and streams logs — it is simply no longer the author of record.

## Layout

- `packages/` — shared hardware definitions. `houzetek-smart-plug.yaml` is used by both
  `power-outlet` and `iron-outlet`.
- `devices/` — per-device substance for devices that do not share hardware.

## The stub contract

Each device keeps a **stub** at `/config/<device>.yaml` on the `esp-home` PVC. A stub may contain
**only**:

1. `substitutions` — including every `!secret` lookup
2. `packages` — the reference to this directory
3. Behaviour deliberately kept dashboard-tunable (e.g. `iron-outlet`'s auto-off timer)

A stub must **never** duplicate a key its package already defines.

⚠️ Local values win **permanently and silently**. A stale block left in a stub means you edit this
repo, compile, observe no change, and get no warning at all. If a change here appears to have no
effect, read the stub first.

## Secrets

`secrets.yaml` stays on the PVC and is never committed. ESPHome **forbids** `!secret` inside a
remote package, so credentials cannot reach this public repo even by accident. Stubs read
`!secret` and pass values in as substitutions; packages consume `${...}`.

⚠️ `esphome config` prints resolved secrets in **plaintext** when its output is not a TTY. ESPHome
conceals them with ANSI escapes that only work in an interactive terminal, so a piped or redirected
dump contains the real WiFi password and API key. Never redirect a full `esphome config` dump to a
file or paste one into a log. Extract only what you need — `grep -oE "name: .*"` is safe.

## Cache

Remote package content is cached under `/config/.esphome/packages/<hash>/`. That path is on a
**separate volume** from `/config` (the disposable `esp-home-cache` PVC), so it can be wiped
without touching stubs or secrets. Stubs use `refresh: 0s` so a commit is picked up on the next
compile with no cache flush; `ref:` accepts a branch or a full commit SHA if pinning is ever wanted.
