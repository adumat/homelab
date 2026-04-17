# navi — Docker LXC (runs doco-cd → matchbox for PXE boot)
#
# Privileged Alpine LXC with Docker CE. doco-cd polls the git
# repo and manages matchbox container.

resource "proxmox_virtual_environment_container" "navi" {
  node_name = var.proxmox_node
  vm_id     = local.services.proxmox.docker_lxc.vmid

  description = "Docker LXC - doco-cd + matchbox"
  tags        = ["docker", "pxe"]

  started       = true
  start_on_boot = true
  unprivileged  = false # Docker needs privileged LXC

  operating_system {
    template_file_id = "local:vztmpl/alpine-3.23-default_20260116_amd64.tar.xz"
    type             = "alpine"
  }

  cpu {
    cores = local.services.proxmox.docker_lxc.cores
  }

  memory {
    dedicated = local.services.proxmox.docker_lxc.memory
  }

  disk {
    datastore_id = "local-lvm"
    size         = local.services.proxmox.docker_lxc.disk_size
  }

  # Servers VLAN 10 — for matchbox PXE/HTTP
  network_interface {
    name        = "eth0"
    bridge      = proxmox_network_linux_bridge.lan.name
    vlan_id     = local.zones.servers.vlan_id
    mac_address = "BC:24:11:7D:21:95"
  }

  features {
    nesting = true # Required for Docker-in-LXC
    keyctl  = true # Required for Docker
  }

  initialization {
    hostname = "navi"

    ip_config {
      ipv4 {
        address = "10.1.10.5/24"
        gateway = local.zones.servers.gateway
      }
    }

    dns {
      servers = [local.zones.servers.gateway]
      domain  = local.services.domain
    }
  }
}
