# Device Inventory

## VLAN 1 — Untrusted (Area 51)

No devices assigned. Client isolation enabled.
Default VLAN — any untagged port gets untrusted by default.

## VLAN 10 — Servers (The Matrix)

| Device | MAC | Static IP | Connection |
|--------|-----|-----------|------------|
| elizabeth (NAS) | 14:da:e9:4d:e7:65 | 10.1.10.2 | Wired HPE port 17 |
| donkey | ee:33:32:65:7e:84 | 10.1.10.3 | Wired HPE port 18 |
| kube-nuc | 1c:69:7a:a5:93:fc | 10.1.10.10 | Wired HPE port 21 |
| kube-hp | f8:b4:6a:a5:87:ed | 10.1.10.11 | Wired HPE port 19 |
| kube-ceph-01 | e8:6a:64:a4:89:ca | 10.1.10.21 | Wired HPE port 22 |
| kube-ceph-02 | e8:6a:64:f6:ff:af | 10.1.10.22 | Wired HPE port 23 |
| kube-ceph-03 | e8:6a:64:76:2a:18 | 10.1.10.23 | Wired HPE port 24 |
| matryoshka (Proxmox) | — | 10.1.10.9 | VM host (vmbr0.10) |
| navi (Docker LXC) | — | 10.1.10.5 | LXC on matryoshka (VLAN 10) |
| switch-main (HPE 1820) | 04:09:73:36:1b:a0 | 10.1.10.4 | — |
| U6-PT (AP ground floor) | 0c:ea:14:7c:1d:01 | 10.1.10.50 | Wired HPE port 3 |
| U6-P1 (AP 1st floor) | 0c:ea:14:7c:1f:51 | 10.1.10.51 | Wired HPE port 1 |
| U6-EXT (AP outdoor) | d8:b3:70:e9:e0:82 | 10.1.10.52 | Wired HPE port 2 |

## VLAN 20 — Clients (LAN Solo)

| Device | MAC | Static IP | Connection | Notes |
|--------|-----|-----------|------------|-------|
| Matteos-MBP | ac:07:75:3b:85:0a | — | WiFi PT/P1 | |
| iPhone (Matteo) | 22:fa:fb:29:f8:3f | — | WiFi P1 | |
| Matteos-iPhone | 38:65:b2:d1:ca:de | — | WiFi | |
| iPhone-di-Elisa | 34:fe:77:8f:54:37 | — | WiFi | |
| Galaxy-S9 | 26:ff:35:4e:c2:a2 | — | WiFi P1 | |
| thermomix | 94:09:c9:b8:dd:2a | — | WiFi | |
| 76:2b:f9 (unknown phone) | 76:2b:f9:a5:f7:e0 | — | WiFi EXT | Randomized MAC |
| switch-living (TP-Link) | d8:07:b6:d7:94:67 | 10.1.20.11 | Wired HPE port 15 | Dumb switch |
| PS5 | 80:60:b7:10:03:3e (WiFi) | 10.1.20.30 | WiFi EXT | |
| PS5 | 78:c8:81:cf:4a:27 (LAN) | 10.1.20.31 | Wired (TP-Link) | Separate reservation per MAC |

### Shared devices (10.1.20.20-29 — accessible from Guest VLAN)

| Device | MAC | Static IP | Connection |
|--------|-----|-----------|------------|
| LG TV (webOS) | c0:d7:aa:8e:ca:18 | 10.1.20.20 | WiFi P1 |
| Samsung TV | b0:f2:f6:77:40:24 | 10.1.20.21 | WiFi |
| EPSON printer | dc:cd:2f:6f:1b:07 | 10.1.20.22 | WiFi P1 |

## VLAN 30 — IoT (R2D2 Net)

| Device | MAC | Static IP | Connection | Notes |
|--------|-----|-----------|------------|-------|
| C200 (TP-Link cam) | 34:60:f9:4b:b2:8d | — | WiFi P1 | |
| C210 (TP-Link cam) | ec:75:0c:11:61:1c | — | WiFi EXT | |
| G7-ThinQ (LG washer) | 48:60:5f:6b:0e:b8 | — | WiFi P1 | |
| LG Smart Dryer | 80:5b:65:67:16:b0 | — | WiFi PT | |
| dreame vacuum | 70:c9:32:44:77:59 | — | WiFi P1 | |
| SolarEdge inverter | 84:d6:c5:58:d9:b0 | 10.1.30.50 | Wired HPE port 16 | |

### Shared devices (10.1.30.20-29 — accessible from Guest VLAN)

| Device | MAC | Static IP | Connection |
|--------|-----|-----------|------------|
| Google Home | 00:f6:20:dc:f9:9b | 10.1.30.20 | WiFi EXT |

## VLAN 40 — IoT-Local (Skynet Local)

| Device | MAC | Static IP | Connection | Notes |
|--------|-----|-----------|------------|-------|
| hvac-controller | f0:9e:9e:54:c1:a4 | — | WiFi PT | No internet |
| iron-outlet (ESP) | b4:e6:2d:5d:73:88 | — | WiFi P1 | No internet |
| power-outlet (ESP) | b4:e6:2d:5d:62:9b | — | WiFi PT | No internet |

## VLAN 50 — Guest (FBI Surveillance Van)

Dynamic only. Client isolation enabled.
Can access shared devices: 10.1.20.20/28 (TVs, printer) and 10.1.30.20/28 (Google Home).
