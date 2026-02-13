# Kubernetes Cluster Bootstrap

Bootstrap procedures for the Kubernetes cluster running on Talos Linux.

## Prerequisites

- [mise](https://mise.jdx.dev/) installed and activated (`mise install` from repo root)
- Talos nodes booted from ISO (see [Machine Preparation](#machine-preparation))
- `talconfig.yaml` and `talenv.yaml` configured in `kubernetes/talos/`
- Bitwarden Secrets Manager access token configured in `.env`

## Machine Preparation

1. Go to [Talos Linux Image Factory](https://factory.talos.dev) and build an image with the system
   extensions defined in `kubernetes/talos/talconfig.yaml` (i915, intel-ucode, iscsi-tools, mei,
   nfsrahead, nut-client, nvme-cli, util-linux-tools).

2. Generate the schematic ID:

   ```sh
   just talos gen-schematic-id
   ```

3. Flash the ISO to a USB drive and boot each node.

4. Verify the nodes are reachable:

   ```sh
   nmap -Pn -n -p 50000 192.168.1.0/24 -vv | grep 'Discovered'
   ```

## Bootstrap

Run the full bootstrap sequence:

```sh
just bootstrap default
```

This executes the following stages in order:

| # | Command | Description |
|---|---------|-------------|
| 1 | `just bootstrap talos` | Apply Talos config to all nodes |
| 2 | `just bootstrap kube` | Bootstrap the Kubernetes API on the controller |
| 3 | `just bootstrap kubeconfig` | Fetch kubeconfig (pre-Cilium, direct to node endpoint) |
| 4 | `just bootstrap wait` | Wait for nodes to be available |
| 5 | `just bootstrap namespaces` | Create namespaces from `kubernetes/apps/` |
| 6 | `just bootstrap resources` | Apply bootstrap secrets (GitHub deploy key + SOPS age key via bws-inject) |
| 7 | `just bootstrap crds` | Install CRDs via helmfile |
| 8 | `just bootstrap apps` | Install core apps: Cilium, CoreDNS, Spegel, cert-manager, External Secrets, Flux |

After stage 8, kubeconfig is fetched again through the Cilium-managed cluster VIP.

Stages can also be run individually if needed.

> It may take 10+ minutes for the cluster to fully come up. Errors like "couldn't get current
> server API group list" or nodes showing as NotReady are normal until Cilium is deployed.

## Post-Bootstrap Verification

Check Cilium status:

```sh
cilium status
```

Check Flux status:

```sh
flux check
flux get sources git -A
flux get ks -A
flux get hr -A
```

Watch all pods come up:

```sh
kubectl get pods -A --watch
```
