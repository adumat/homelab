# Network Switches

## VLANs

| VLAN ID | Name | Subnet | Purpose |
|---------|------|--------|---------|
| 1 | Management | 10.1.1.0/24 | Switches, APs, VyOS mgmt |
| 10 | Servers | 10.1.10.0/24 | K8s nodes, donkey, elizabeth |
| 20 | Clients | 10.1.20.0/24 | Laptops, phones, tablets |
| 30 | IoT | 10.1.30.0/24 | Smart devices with internet |
| 40 | IoT-Local | 10.1.40.0/24 | Sensors, ESP — no internet |
| 50 | Untrusted | 10.1.50.0/24 | Restricted devices |
| 60 | Guest | 10.1.60.0/24 | Guest WiFi — internet only |

---

## HPE 1820 24G PoE+ (switch-main)

- **IP**: 10.1.1.10 (DHCP static, management VLAN)
- **Web UI**: http://10.1.1.10
- **Ports 1-12**: PoE+
- **Ports 13-24**: non-PoE

### Port Map

| Port | PoE | Patch | Device | VLAN | Mode |
|------|-----|-------|--------|------|------|
| 1 | yes | 3 | U6-P1 (AP 1st floor) | all | trunk |
| 2 | yes | 2 | U6-EXT (AP outdoor) | all | trunk |
| 3 | yes | 4 | U6-PT (AP ground floor) | all | trunk |
| 4 | yes | — | — | — | — |
| 5 | yes | — | — | — | — |
| 6 | yes | — | — | — | — |
| 7 | yes | — | — | — | — |
| 8 | yes | — | — | — | — |
| 9 | yes | — | — | — | — |
| 10 | yes | — | — | — | — |
| 11 | yes | — | — | — | — |
| 12 | yes | — | — | — | — |
| 13 | no | — | glados LAN | all | trunk |
| 14 | no | — | donkey | 10 | access |
| 15 | no | 6 | switch-living (TP-Link) | 20 | access |
| 16 | no | 5 | SolarEdge inverter | 30 | access |
| 17 | no | 16 | elizabeth (NAS) | 10 | access |
| 18 | no | — | — | — | — |
| 19 | no | 17 | kube-hp | 10 | access |
| 20 | no | 18 | FritzBox | — | removed at cutover |
| 21 | no | 19 | kube-nuc | 10 | access |
| 22 | no | 20 | kube-ceph-01 | 10 | access |
| 23 | no | 21 | kube-ceph-02 | 10 | access |
| 24 | no | 22 | kube-ceph-03 | 10 | access |

### Patch Panel (C5e)

| Patch | Label | Destination |
|-------|-------|-------------|
| 1 | TEL | Telephone (not used) |
| 2 | AP EXT | U6-EXT outdoor AP |
| 3 | AP 1F | U6-P1 first floor AP |
| 4 | AP GF | U6-PT ground floor AP |
| 5 | INV | SolarEdge inverter |
| 6 | LV | Living room → switch-living |
| 16 | — | elizabeth (NAS) |
| 17 | — | kube-hp |
| 18 | — | glados LAN |
| 19 | — | kube-nuc |
| 20 | — | kube-ceph-01 |
| 21 | — | kube-ceph-02 |
| 22 | — | kube-ceph-03 |
| 23 | — | glados WAN |

---

## TP-Link TL-SG105E (switch-living)

- **IP**: 10.1.20.11 (DHCP static, clients VLAN)
- **Web UI**: http://10.1.20.11
- **Note**: No 802.1Q with custom VLAN IDs (only 2-5).
  Connected to HPE port 15 (VLAN 20 access) — dumb switch
  extending Clients network to the living room.

| Port | Device |
|------|--------|
| 1 | HPE uplink (patch 6) |
| 2 | |
| 3 | |
| 4 | |
| 5 | |

---

## Cutover Cable Change

```
Before:  FritzBox LAN → HPE port 20 (patch 18)
         glados LAN → HPE port 13
After:   FritzBox LAN → glados USB NIC (WAN) via patch 23
         glados LAN → HPE port 13 (trunk, unchanged)
```

Port 20 becomes free after cutover.

<!-- SETUP INSTRUCTIONS (remove after cutover) -->

---

## Setup Instructions

### Pre-cutover (safe)

1. HPE web UI → create VLANs: 10, 20, 30, 40, 50, 60
2. Port 20 (glados) → trunk (VLAN 1 untagged + 10/20/30/40/50/60 tagged, PVID 1)
3. Leave all other ports unchanged
4. Save

### During cutover (after glados WAN is up)

1. Ports 14, 17, 19, 21-24 → access VLAN 10 (servers)
2. Ports 1, 2, 3 → trunk (APs)
3. Port 15 → access VLAN 20 (TP-Link)
4. Port 16 → access VLAN 30 (SolarEdge)
5. Keep one port on VLAN 1 for management
6. Save
