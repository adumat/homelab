locals {
  networks = yamldecode(file("${path.module}/data/networks.yaml"))
  services = yamldecode(file("${path.module}/data/services.yaml"))

  # ── Network zones ──────────────────────────────────────
  zones      = local.networks.zones
  zone_names = keys(local.zones)

  # Cilium LB pool (BGP-only, no VLAN)
  k8s_lb_subnet  = local.networks.k8s_lb_subnet
  k8s_gateway_ip = local.networks.k8s_gateway_ip

  # Domains Unbound forwards to k8s-gateway. Services advertise themselves
  # under these domains via external-dns.alpha.kubernetes.io/hostname.
  # base_domain is nonsensitive()'d because it becomes a resource instance key.
  k8s_gateway_forward_domains = [
    nonsensitive(var.base_domain),
  ]

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

  # ── Zone to OPNsense interface name mapping ─────────────
  # VLAN 1 (untrusted) = lan (untagged)
  # VLANs assigned in order: opt1=vlan0.10, opt2=vlan0.20, ...
  # VPN = wg0
  #
  # Sorted VLAN zones (excluding VLAN 1 and null) determine opt numbering
  sorted_vlan_ids = sort([
    for name, zone in local.zones : tostring(zone.vlan_id)
    if zone.vlan_id != null && zone.vlan_id != 1
  ])

  vlan_to_opt = {
    for idx, vid in local.sorted_vlan_ids :
    vid => "opt${idx + 1}"
  }

  # OPNsense interface identifiers for firewall rules
  # opt1-5 = VLANs (sorted by ID), opt6 = wg0
  zone_interface = {
    for name, zone in local.zones : name =>
    zone.vlan_id == null ? "opt${length(local.sorted_vlan_ids) + 1}" :
    zone.vlan_id == 1 ? "lan" :
    local.vlan_to_opt[tostring(zone.vlan_id)]
  }

  # VLAN device names (vlan0.XX format)
  zone_device = {
    for name, zone in local.zones : name =>
    zone.vlan_id == null ? "wg0" :
    zone.vlan_id == 1 ? "lan" :
    "vlan0.${zone.vlan_id}"
  }

  # ── Firewall inter-zone rules (flattened) ──────────────
  # Rule numbering: 100 + src_idx * 100 + dst_idx * 10 + sub_rule
  firewall_rules = flatten([
    for src_name, src_zone in local.zones : [
      for dst_name, policy in try(src_zone.access, {}) : {
        src        = src_name
        dst        = dst_name
        policy     = policy
        rule_base  = 100 + index(local.zone_names, src_name) * 100 + index(local.zone_names, dst_name) * 10
        src_device = local.zone_interface[src_name]
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
