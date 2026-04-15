# Bootstrap Guide

Step-by-step guide to set up matryoshka (Proxmox) + glados (OPNsense) from scratch.

## 1. Hardware Prep

- Enable **VT-d/IOMMU** in BIOS (Dell OptiPlex 7060: BIOS → Virtualization Support)
- Connect Intel onboard NIC to HPE switch trunk port
- Connect USB Realtek NIC to FritzBox LAN

## 2. Install Proxmox VE

- Download ISO: https://www.proxmox.com/en/downloads
- Flash to USB, boot, install
- Hostname: `matryoshka`
- Management IP: on Intel onboard NIC (will become vmbr0/LAN)

## 3. Download Resources (from your Mac)

```bash
./infra/scripts/bootstrap.sh download
```

## 4. Proxmox Credentials

Use `root@pam` username/password auth (required for privileged LXC).

Update `infra/secrets.auto.tfvars` with Proxmox credentials, or run:
```bash
./infra/scripts/sync-secrets.sh
```

## 5. Upload Resources to Proxmox

```bash
./infra/scripts/bootstrap.sh upload matryoshka:8006
```

## 6. Apply Proxmox Layer

```bash
cd infra
tofu init
tofu import proxmox_network_linux_bridge.lan matryoshka:vmbr0
tofu apply -target=proxmox_network_linux_bridge.wan \
           -target=proxmox_virtual_environment_vm.glados \
           -target=proxmox_virtual_environment_container.navi
```

## 7. Install OPNsense

- Proxmox UI → glados (VM 100) → Hardware → Add CD/DVD → select OPNsense ISO
- Set boot order: CD first
- Start VM, open console
- Install OPNsense (UFS filesystem)
- Remove CD after install, reboot

## 8. OPNsense Initial Setup

Default login: `root` / `opnsense`

### System Settings (manual — no API)

**System → Settings → General:**
- Hostname: `glados`
- Domain: `lan`
- Timezone: `Europe/Rome`

**Services → Network Time → General:**
- NTP servers: `0.it.pool.ntp.org`, `1.it.pool.ntp.org`, `2.it.pool.ntp.org`, `3.it.pool.ntp.org`
- Interface: LAN + all VLAN interfaces
- ACL: `10.1.0.0/16`

### Create API Key

System → Access → Users → root → API keys → Add

Save key+secret to `infra/secrets.auto.tfvars`.

### Install Required Plugins

System → Firmware → Plugins:

| Plugin | Purpose |
|--------|---------|
| `os-frr` | BGP peering with Cilium (FRR/Quagga) |
| `os-ddclient` | Dynamic DNS for Cloudflare |
| `os-tftp` | TFTP server for PXE boot |
| `os-node_exporter` | Prometheus metrics for monitoring |

Reboot after installing plugins.

## 9. Apply OPNsense Layer

```bash
cd infra
tofu apply
```

This creates: VLANs, DHCP, DNS, firewall rules, NAT, WireGuard, BGP, DDNS, TFTP.

## 10. Bootstrap navi (Docker LXC)

```bash
./infra/scripts/bootstrap-navi.sh 10.1.10.5 10.1.1.1 --token <git-token> --bws-token <bws-token>
```

This will:
- Install Docker + dependencies on navi
- Upload and run doco-cd bootstrap (deploys matchbox for PXE boot)
- Download iPXE files and upload to glados TFTP directory

## 11. Verify

- [ ] Proxmox UI: `https://10.1.1.1:8006`
- [ ] OPNsense UI: `https://10.1.1.1`
- [ ] VLANs: 7 zones visible in Interfaces
- [ ] DHCP: leases appearing per zone
- [ ] DNS: `dig @10.1.10.1 google.com` resolves
- [ ] Firewall: inter-zone rules in Firewall → Rules
- [ ] BGP: Routing → BGP → 5 neighbors
- [ ] WireGuard: VPN → WireGuard → server + 2 peers
- [ ] PXE: `curl http://10.1.10.5:8085/boot.ipxe` returns chain script
