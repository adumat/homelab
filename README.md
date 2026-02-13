# Homelab

Personal homelab infrastructure-as-code repository. Manages bare-metal servers running
Docker Compose services and a Kubernetes cluster, all deployed via GitOps.

## Repository Structure

```
.
├── docker/
│   ├── doco-cd/          # GitOps CD for Docker Compose services
│   ├── donkey/           # Services running on donkey
│   └── elizabeth/        # Services running on elizabeth (placeholder)
├── kubernetes/
│   ├── apps/             # Flux-managed application deployments
│   ├── bootstrap/        # Cluster bootstrap (helmfile, resources)
│   ├── components/       # Shared Kustomize components
│   ├── flux/             # Flux cluster configuration
│   └── talos/            # Talos node configuration (talhelper)
└── scripts/              # Shared shell utilities
```

## Hardware

### Servers

| Hostname  | IP          | Hardware                                        | Role           |
|-----------|-------------|-------------------------------------------------|----------------|
| donkey    | 192.168.1.3 | Pine64 RockPro64                                | Infrastructure |
| elizabeth | 192.168.1.2 | i5-2500K, ASUS P8P67 Pro, 2x8TB + 1x10TB       | NAS (Unraid)   |

### Kubernetes Nodes

All nodes run Talos Linux on amd64 hardware.

| Hostname     | IP            | Hardware                  | Role          | Disk                        |
|--------------|---------------|---------------------------|---------------|-----------------------------|
| kube-nuc     | 192.168.1.30  | Intel NUC 10              | Control plane | Samsung 970 EVO Plus 500GB  |
| kube-hp      | 192.168.1.32  | HP 800 G4 Mini, i5-8500   | Control plane | WDC SN720 256GB             |
| kube-ceph-01 | 192.168.1.33  | Lenovo M720Q Tiny, i5     | Worker        | Kingston SA400S3             |
| kube-ceph-02 | 192.168.1.34  | Lenovo M720Q Tiny, i5     | Worker        | SanDisk SD9TB8W2            |
| kube-ceph-03 | 192.168.1.35  | Lenovo M720Q Tiny, i5     | Worker        | SanDisk SD9TB8W2            |

> kube-dell (192.168.1.31) is currently inactive.

### Network Devices

| Device        | IP            | Model                                        |
|---------------|---------------|----------------------------------------------|
| switch-main   | 192.168.1.10  | HPE OfficeConnect 1820 24G PoE+ (J9983A)     |
| switch-living | 192.168.1.11  | TP-Link TL-SG105E                            |
| U6-PT         | 192.168.1.50  | UniFi AP                                     |
| U6-P1         | 192.168.1.51  | UniFi AP                                     |
| U6-EXT        | 192.168.1.52  | UniFi AP                                     |

## Servers

### donkey

Pine64 RockPro64 — infrastructure server running Docker Compose services.

| Service        | Description                           |
|----------------|---------------------------------------|
| dnsmasq        | DNS, DHCP, PXE/iPXE boot             |
| matchbox       | Bare-metal provisioning (Talos)       |
| adguard        | DNS ad-blocking                       |
| chrony         | NTP time server                       |
| nut            | UPS monitoring (NUT server)           |
| power-nap-over | Power management / Wake-on-LAN        |
| backup         | Docker volume backups                 |

Service definitions: [`docker/donkey/`](docker/donkey/)

### elizabeth

i5-2500K / ASUS P8P67 Pro — NAS and storage server running Unraid (2x8TB + 1x10TB).

> Docker Compose services for elizabeth are not yet configured.
> See [`docker/elizabeth/`](docker/elizabeth/).

## Kubernetes Cluster

| Component     | Tool / Project                          |
|---------------|-----------------------------------------|
| OS            | Talos Linux v1.12.1                     |
| Kubernetes    | v1.34.1                                 |
| GitOps        | Flux CD                                 |
| CNI           | Cilium                                  |
| Storage       | Rook-Ceph                               |
| Ingress       | Envoy Gateway                           |
| Certificates  | cert-manager                            |
| Secrets       | SOPS + Age, External Secrets, BWS       |
| DNS (internal)| AdGuard + dnsmasq + k8s-gateway         |
| DNS (external)| external-dns (Cloudflare)               |
| Monitoring    | kube-prometheus-stack                    |
| Registry      | Spegel (mirror)                         |

### Network

| Address       | Purpose                             |
|---------------|-------------------------------------|
| 192.168.1.40  | Cluster VIP (k8s.clusterone.lan)    |
| 192.168.1.41  | k8s-gateway                         |
| 192.168.1.42  | Internal ingress                    |
| 192.168.1.43  | External ingress                    |

Internal domain: `.lan` / `.clusterone.lan`. External access via Cloudflare Tunnel.

## GitOps

### Docker Compose — doco-cd

[doco-cd](https://github.com/kimdre/doco-cd) polls this repository every 180 seconds and applies
Docker Compose changes to the matching server profile (donkey or elizabeth).

See [docker/doco-cd/README.md](docker/doco-cd/README.md) for bootstrap instructions.

### Kubernetes — Flux CD

Flux watches the `kubernetes/` directory and reconciles the cluster state from Git.

See [kubernetes/bootstrap/README.md](kubernetes/bootstrap/README.md) for bootstrap instructions.

## Dev Tools

Managed by [mise](https://mise.jdx.dev/). Run `mise install` to set up the local environment.
Task runner: [just](https://github.com/casey/just). Run `just -l` to list available commands.

## Links

- [Kubernetes cluster bootstrap](kubernetes/bootstrap/README.md)
- [Docker CD bootstrap](docker/doco-cd/README.md)
- [Operations runbook](runbook.md)
