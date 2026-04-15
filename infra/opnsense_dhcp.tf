# Kea DHCP — one subnet per zone, static reservations from networks.yaml

resource "opnsense_kea_subnet" "zone" {
  for_each = local.dhcp_zones

  subnet      = each.value.subnet
  description = "${each.key} DHCP"
  pools       = ["${each.value.dhcp.range_start}-${each.value.dhcp.range_stop}"]
  routers     = [each.value.gateway]
  domain_name = local.services.domain
  dns_servers = [each.value.gateway]
}

resource "opnsense_kea_reservation" "host" {
  for_each = {
    for host in local.all_static_hosts : host.name => host
  }

  subnet_id   = opnsense_kea_subnet.zone[each.value.zone].id
  ip_address  = each.value.ip
  mac_address = each.value.mac
  hostname    = each.value.name
  description = "${each.value.name} (${each.value.zone})"
}
