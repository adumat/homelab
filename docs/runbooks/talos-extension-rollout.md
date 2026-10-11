# A new system extension only reaches a node through a tuppr upgrade

Extensions are baked into the boot image, so a new one only reaches a node through a
reinstall. Upgrades are driven by tuppr's `TalosUpgrade`, and **tuppr resolves the installer
image from the node's runtime state**, not from `talconfig.yaml`:

1. `tuppr.home-operations.com/factory-url` annotation → builds `<factory-url>/<schematic>:<version>`,
   taking the schematic from the `tuppr.home-operations.com/schematic` annotation if set,
   otherwise from the node's runtime `ExtensionStatus`
2. otherwise, version-swap the node's current `.machine.install.image`
3. safety net → **refuse** when the runtime schematic is not in the install-image path

So editing `officialExtensions` and running `apply-config` is *not* enough, and it is worse
than a no-op: the new schematic in `.machine.install.image` no longer matches the running
one, so path 3 parks the whole run. Annotate every node with `factory-url` **and**
`schematic` before letting the version bump reach the cluster.

Get the ID with `just talos gen-schematic-id` — it POSTs the schematic to the factory, which
both registers it and returns the ID. Confirm it actually changed; an unchanged ID means the
edit missed the top-level `.schematic` in `talconfig.yaml`, which is what that recipe reads.

⚠️ **Remove the annotations once the rollout is verified — but in this order.** First
`just talos apply-node <ip>` on every node, so
`.machine.install.image` carries the new schematic and matches what is running; only then
`kubectl annotate node --all tuppr.home-operations.com/factory-url- .../schematic-`. Removing
them first leaves the runtime schematic absent from the install-image path, which is the case
path 3 refuses — the *next* upgrade parks. Leaving them set is the other failure: they pin the
schematic, so a later extension change never reaches the nodes.

Pair the extension change with a Talos version bump when one is pending: tuppr triggers on
version drift, so a schematic change alone gives it no reason to act.
