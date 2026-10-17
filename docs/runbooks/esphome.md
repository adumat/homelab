# ESPHome

Device config lives in `esphome/` and is pulled via ESPHome remote packages. `/config` on the
`esp-home` PVC holds only thin stubs (`substitutions` + `packages` + intentionally-local behaviour)
plus `secrets.yaml`, and is never committed.

⚠️ A stub that duplicates a key its package defines wins **permanently and silently** — you will
edit the repo, compile, and see no change with no warning. If a config change appears to do
nothing, read the stub before anything else.

⚠️ `esphome config` prints resolved secrets in plaintext when output is not a TTY (the ANSI conceal
escapes only hide them in an interactive terminal). Never redirect a full dump to a file or paste
one anywhere; extract only the lines you need.

⚠️ `power-outlet` and `iron-outlet` are 1 MB esp8285 parts with roughly 16 KiB of OTA headroom.
Before flashing either, compare the new `firmware.ota.bin` against the recorded baseline
(power-outlet 501520, iron-outlet 503472 bytes) — it must be **smaller**. A too-large image is
accepted by the build and then rejected by OTA, leaving the device on old firmware and needing USB
recovery.

---
