# Linux bridges on Proxmox
#
# vmbr0 (LAN): eno1 → VLAN-aware trunk, mgmt IP 10.1.1.2 (untagged = VLAN 1)
# vmbr1 (WAN): eno2 → OPNsense WAN (FritzBox)
#
# vmbr0.10 for Proxmox servers access is in /etc/network/interfaces (not TF).
# VMs/LXCs use VLAN tags when attaching to vmbr0.
#
# Import vmbr0: tofu import proxmox_network_linux_bridge.lan matryoshka:vmbr0

resource "proxmox_network_linux_bridge" "lan" {
  node_name  = var.proxmox_node
  name       = "vmbr0"
  vlan_aware = true
  comment    = "LAN trunk - VLAN-aware"
  ports = [
    "nic0"
  ]
  lifecycle {
    ignore_changes = all
  }
}

resource "proxmox_network_linux_bridge" "wan" {
  node_name = var.proxmox_node
  name      = "vmbr1"
  comment   = "WAN - FritzBox LAN"
  ports = [
    "nic1"
  ]
}
