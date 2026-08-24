# Runbook

Operations reference for day-to-day cluster and service management.

## Flux

Show all Flux objects that are not ready:

```sh
flux get all -A --status-selector ready=false
```

Show Flux warning events:

```sh
kubectl get events -n flux-system --field-selector type=Warning
```

Force reconcile:

```sh
just kube sync-git    # GitRepositories
just kube sync-ks     # Kustomizations
just kube sync-hr     # HelmReleases
just kube sync-oci    # OCIRepositories
just kube sync-es     # ExternalSecrets
```

## Talos Node Management

Apply config to a node:

```sh
just talos apply-node <node-ip>
```

Upgrade Talos on a node:

```sh
just talos upgrade-node <node-ip> <version>
```

Upgrade Kubernetes cluster-wide:

```sh
just talos upgrade-k8s <version>
```

Reboot / shutdown / reset a node:

```sh
just talos reboot-node <node-ip>
just talos shutdown-node <node-ip>
just talos reset-node <node-ip>
```

> Resetting nodes multiple times in a short period could lead to rate limiting
> by container registries or Let's Encrypt.

### Two reset modes, and why the default is the safe one

`reset-node` / `reset-all-nodes` use `--system-labels-to-wipe EPHEMERAL,STATE`, which **keeps
other partitions intact** — including the ESP. That matters more than it looks:

**Talos >= v1.11.0 writes a `Talos Linux UKI` EFI boot entry on install and never removes it on
reset.** There is no config knob, no reset flag, and efivarfs is mounted `ro`, so the entry
cannot be deleted from a running node.

- **Default (`EPHEMERAL,STATE`)** — the bootloader survives, so the entry stays *valid*. The node
  boots from its own disk into maintenance mode and you apply config with **no PXE involved**.
  This is what you want almost always.
- **`--wipe-mode all`** — destroys the ESP too, leaving the boot entry pointing at a partition
  UUID that no longer exists. The node can then only come up over PXE, and **HP firmware halts at
  `3F0` instead of falling through** to the network entry. Reach for this only when disk
  signatures or partition sizes must change (phase 3 needed it to clear Ceph BlueStore
  signatures). The entry self-heals on the next install.

A leftover signature can still refuse `pvcreate` after a full wipe. Clear it per disk with:

```sh
talosctl -n <node-ip> wipe disk <device> --insecure   # e.g. nvme0n1; --insecure AFTER the subcommand
```

## Kubernetes Utilities

Apply a local Flux Kustomization:

```sh
just kube apply-ks <namespace> <kustomization>
```

Delete a local Flux Kustomization:

```sh
just kube delete-ks <namespace> <kustomization>
```

Browse a PVC:

```sh
just kube browse-pvc <namespace> <claim>
```

Open a shell on a node:

```sh
just kube node-shell <node>
```

Prune failed/pending/succeeded pods:

```sh
just kube prune-pods
```

View a decrypted secret:

```sh
just kube view-secret <namespace> <secret>
```

Trigger VolSync snapshots:

```sh
just kube snapshot
```

Suspend / resume KEDA or VolSync:

```sh
just kube keda suspend
just kube keda resume
just kube volsync suspend
just kube volsync resume
```

## Debugging

Inspect pods:

```sh
kubectl -n <namespace> get pods -o wide
```

Follow logs:

```sh
kubectl -n <namespace> logs <pod> -f
```

Describe a resource:

```sh
kubectl -n <namespace> describe <resource> <name>
```

View namespace events:

```sh
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
```

Inspect a SQLite database inside a pod:

```sh
kubectl -n <namespace> exec -it <pod> -- sqlite3 /path/to/db.sqlite
```

Or copy it locally first:

```sh
kubectl cp <namespace>/<pod>:/path/to/db.sqlite ./db.sqlite
sqlite3 ./db.sqlite
```

## Docker Compose (doco-cd)

Check doco-cd logs:

```sh
docker compose --project-directory docker/doco-cd logs -f
```

Check service status:

```sh
docker compose --project-directory docker/doco-cd --profile <profile> ps
```

Restart doco-cd:

```sh
docker compose --project-directory docker/doco-cd --profile <profile> restart
```
