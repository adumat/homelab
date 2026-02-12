# FLUX

Show all Flux objects that are not ready

```bash
flux get all -A --status-selector ready=false
```

Show flux warning events

```bash
kubectl get events -n flux-system --field-selector type=Warning
```
