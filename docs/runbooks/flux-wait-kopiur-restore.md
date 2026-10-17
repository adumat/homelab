# Flux `wait: true` deadlocks forever on a *completed* kopiur `Restore`

unifi-mongo's Kustomization has `wait: true`, and it sat at `Ready=Unknown` for hours repeating:

```
health check failed after 10m0.045278957s: timeout waiting for: [Restore/network/unifi-mongo status: 'InProgress']
```

The Restore had been `Completed` for **45 hours**. `InProgress` is not even one of its phases
(`Pending`/`Resolving`/`Restoring`/`Completed`/`Failed`) — it is kstatus's own verdict, which it
returns whenever `status.observedGeneration < metadata.generation`:

```
restore:          gen=2  obsGen=1   phase=Completed   <- wedged
snapshotpolicy:   gen=3  obsGen=3
snapshotschedule: gen=5  obsGen=5
```

A `Restore` stops being reconciled once it reaches a terminal phase, so a later re-apply that
bumps `generation` — editing `components/kopiur/restore.yaml` does exactly that to every app —
is never observed. The health check can then **never** pass, and every app that `dependsOn` that
Kustomization is gated behind it indefinitely. unifi's pod sat `Pending` with no PVC while its
own status said only "dependency not ready", naming nothing useful.

**This is systemic, not one bad object.** Every migrated app's Restore carries the identical
lag — 12 of 12 at `gen=2 obsGen=1`. `wait: false` merely hides it, so *any* app that is ever
given `wait: true` will deadlock the same way.

⚠️ **`healthCheckExprs` does not fix it.** The obvious answer is to teach Flux to read the phase:

```yaml
  healthCheckExprs:            # DOES NOT WORK for this
    - apiVersion: kopiur.home-operations.com/v1alpha1
      kind: Restore
      current: status.phase == 'Completed'
```

Measured: with those exprs live on the Kustomization, the verdict was byte-identical after a full
10-minute window. kstatus applies the `observedGeneration` precondition *before* evaluating the
CEL, so the expression is never reached. Proven by isolating the one variable —

```sh
kubectl patch restore <app> -n <ns> --subresource=status --type=merge \
  -p '{"status":{"observedGeneration":2}}'
```

— after which the same Kustomization went Ready on the very next reconcile. Useful to unblock
*now*, but it is not declarative: Flux never reapplies status, and the next re-apply that bumps
`generation` re-breaks it.

The durable fix is to stop health-checking the Restore at all. `wait: true` is all-or-nothing
over the inventory, so express the real intent with an explicit check instead — helm-controller
already waits for the workload, so a Ready HelmRelease does mean the database is serving:

```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: unifi-mongo
      namespace: network
  wait: false          # required: `wait: true` ignores healthChecks entirely
```

Read the Kustomization's **events**, not its conditions, to see which object a health check is
actually stuck on — the conditions only ever say "Reconciliation in progress":

```sh
kubectl get events -n <ns> --sort-by=.lastTimestamp | grep HealthCheckFailed
```

And do not `git push` while a health check is running: it logs "New revision detected during
health check, cancelling" and restarts the whole window. I did this to myself with a docs commit.
