locals {
  networks = yamldecode(file("${path.module}/data/networks.yaml"))
  services = yamldecode(file("${path.module}/data/services.yaml"))

  # ── Network zones ──────────────────────────────────────
  zones      = local.networks.zones
  zone_names = keys(local.zones)

  # Zones with VLANs (exclude vpn which has vlan_id: null)
  vlan_zones = {
    for name, zone in local.zones : name => zone
    if zone.vlan_id != null
  }

  # Zones with DHCP
  dhcp_zones = {
    for name, zone in local.zones : name => zone
    if try(zone.dhcp, null) != null
  }

  # Zones with client isolation
  isolation_zones = {
    for name, zone in local.zones : name => zone
    if try(zone.client_isolation, false)
  }

  # Zones without internet
  no_internet_zones = {
    for name, zone in local.zones : name => zone
    if try(zone.internet, true) == false
  }

  # ── DHCP static hosts (flattened) ──────────────────────
  all_static_hosts = flatten([
    for zone_name, zone in local.zones : [
      for host in try(zone.static_hosts, []) : {
        zone = zone_name
        name = host.name
        mac  = host.mac
        ip   = host.ip
      }
    ]
  ])

  # ── DNS records ────────────────────────────────────────
  dns_records = local.networks.dns_records

  # ── Firewall inter-zone rules (flattened) ──────────────
  # Rule numbering: 100 + src_idx * 100 + dst_idx * 10 + sub_rule
  firewall_rules = flatten([
    for src_name, src_zone in local.zones : [
      for dst_name, policy in try(src_zone.access, {}) : {
        src       = src_name
        dst       = dst_name
        policy    = policy
        rule_base = 100 + index(local.zone_names, src_name) * 100 + index(local.zone_names, dst_name) * 10
      }
    ]
  ])

  # ── Services ───────────────────────────────────────────
  bgp       = local.services.bgp
  wireguard = local.services.wireguard
  ntp       = local.services.ntp_servers
  tftp      = local.services.tftp
  pxe       = local.services.pxe
}
