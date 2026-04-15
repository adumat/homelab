# glados — OPNsense VM
#
# Initial install: download OPNsense ISO to Proxmox storage,
# boot VM from ISO, complete install via web console, then
# remove cdrom and reboot. After that, OpenTofu manages config
# via the OPNsense API.

resource "proxmox_virtual_environment_vm" "glados" {
  node_name = var.proxmox_node
  vm_id     = local.services.proxmox.opnsense.vmid
  name      = "glados"
  tags      = ["firewall", "opnsense"]

  on_boot = true
  started = true

  cpu {
    cores = local.services.proxmox.opnsense.cores
    type  = "host"
  }

  memory {
    dedicated = local.services.proxmox.opnsense.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "virtio0"
    size         = local.services.proxmox.opnsense.disk_size
    discard      = "on"
    ssd          = true
  }

  # LAN trunk — vmbr0 (Intel onboard, VLAN aware, also Proxmox mgmt)
  network_device {
    bridge   = proxmox_network_linux_bridge.lan.name
    model    = "virtio"
    firewall = false
  }

  # WAN — vmbr1 (USB Realtek bridge)
  network_device {
    bridge   = proxmox_network_linux_bridge.wan.name
    model    = "virtio"
    firewall = false
  }

  operating_system {
    type = "other"
  }

  lifecycle {
    ignore_changes = [
      disk[0].size, # Don't shrink disk after manual resize
      cdrom,        # ISO mount managed manually for installs
    ]
  }
}
