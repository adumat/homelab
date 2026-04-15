# Linux bridges on Proxmox — connect physical NICs to VMs
#
# vmbr0 (LAN): Intel onboard → glados LAN trunk (802.1Q tagged)
#   Created by Proxmox during install. Also carries Proxmox management.
#   Import with: tofu import proxmox_network_linux_bridge.lan pve:vmbr0
#
# vmbr1 (WAN): USB Realtek → glados WAN

resource "proxmox_network_linux_bridge" "lan" {
  node_name  = var.proxmox_node
  name       = "vmbr0"
  vlan_aware = true
  comment    = "LAN trunk - 802.1Q to switch + Proxmox mgmt"

  lifecycle {
    ignore_changes = [address, gateway, ports]
  }
}

resource "proxmox_network_linux_bridge" "wan" {
  node_name = var.proxmox_node
  name      = "vmbr1"
  comment   = "WAN - FritzBox LAN"
}
