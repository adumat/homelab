# Talos Patching

Strategic-merge patches layered onto `machineconfig.yaml.j2` by `just talos render-config`,
via `talosctl machineconfig patch`.

<https://www.talos.dev/latest/talos-guides/configuration/patching/>

- `global/`: applied to every node
- `controller/`: applied to control-plane nodes only

Per-node values (hostname, disk, NIC, VIP, EPHEMERAL size) come from `talconfig.yaml` and are
templated directly into `machineconfig.yaml.j2`, not patched.

A patch may carry `bws://` references: the rendered output is passed through `bws-inject`.
