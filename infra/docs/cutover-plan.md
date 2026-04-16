# Network Segmentation Cutover Plan (Proxmox + OPNsense)

## Current State

- VyOS on glados: partially configured, k8s cluster stuck (etcd broken from IP migration)
- Switch VLANs: already configured on HPE 1820 + TP-Link
- K8s branch `feat/network-segmentation` merged to main
- Donkey: running on 10.1.10.3 with doco-cd services
- Cables: already connected (USB NIC → FritzBox, Intel NIC → HPE trunk)

## Pre-cutover (already done)

- [x] Switch VLANs configured (HPE 1820 + TP-Link)
- [x] K8s manifests updated (Cilium BGP, node IPs, LB pool)
- [x] Talos configs regenerated with new IPs
- [x] Donkey migrated to 10.1.10.3
- [x] OpenTofu config written and tested against live OPNsense
- [x] Cables connected

---

## Phase 1: Install Proxmox + OPNsense + navi

Follow [bootstrap.md](bootstrap.md) steps 1-10.

## Phase 2: Restore Kubernetes cluster

Nodes are wiped (ephemeral reset). Apply fresh configs:

```bash
for ip in 10.1.10.10 10.1.10.11 10.1.10.21 10.1.10.22 10.1.10.23; do
  just talos apply-node $ip
done
just bootstrap
```

- [ ] Talos configs applied to all 5 nodes
- [ ] etcd bootstrapped, kubeconfig updated
- [ ] Flux reconciles all workloads
- [ ] Cilium BGP peers established

## Phase 3: Configure WiFi

- [ ] UniFi controller: create SSIDs per VLAN
  - Area 51 → VLAN 1 (2.4 + 5 GHz, client isolation)
  - The Grid → VLAN 20 (2.4 + 5 GHz)
  - R2D2 Net → VLAN 30 (2.4 GHz)
  - The Void → VLAN 40 (2.4 GHz)
  - LAN Solo → VLAN 50 (2.4 + 5 GHz, client isolation)
  - This Is Fine → VLAN 99 (2.4 + 5 GHz, hidden)
- [ ] Reconnect devices to new SSIDs

## Phase 4: Verify

- [ ] Proxmox UI: `https://10.1.1.1:8006`
- [ ] OPNsense UI: `https://10.1.1.1`
- [ ] DNS: `dig @10.1.10.1 google.com` resolves
- [ ] VLAN isolation: guest ✗ servers, iot_local ✗ internet
- [ ] BGP: 5 peers established, LB routes visible
- [ ] WireGuard: connect from external network
- [ ] PXE: `curl http://10.1.10.5:8085/boot.ipxe`
- [ ] All k8s workloads healthy

## Follow-up

- [ ] USB 2.5GbE NIC for WAN when FTTH arrives
- [ ] mDNS reflector for cross-VLAN IoT discovery
- [ ] Unbound DNSBL blocklists for ad-blocking
