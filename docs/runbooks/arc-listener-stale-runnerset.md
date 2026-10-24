# ARC can bind its listener to an EphemeralRunnerSet it then deletes

Seen on first install, 2026-08-08. Two concurrent reconciles of the same
`AutoscalingRunnerSet` each created an `EphemeralRunnerSet` — identical specHash, different
random suffix. The controller deleted one as a duplicate, but the `AutoscalingListener` had
already been created bound to the loser, together with an RBAC Role scoped to that exact
name. The listener then crash-looped forever on:

```
could not patch ephemeral runner set ... ephemeralrunnersets.actions.github.com "<name>" not found
```

**The controller never re-points an existing listener at the surviving set**, so this does
not self-heal, and restarting the pod does not help — the stale name lives in the
`AutoscalingListener` spec, not in the pod.

Diagnose by comparing the two:

```bash
mise exec -- kubectl get autoscalinglistener -A -o jsonpath='{range .items[*]}{.metadata.name}{"  ers="}{.spec.ephemeralRunnerSetName}{"\n"}{end}'
mise exec -- kubectl get ephemeralrunnerset -n actions-runner-system
```

Fix by deleting the listener; the controller recreates it bound to the surviving set:

```bash
mise exec -- kubectl delete autoscalinglistener <name> -n actions-runner-system
```
