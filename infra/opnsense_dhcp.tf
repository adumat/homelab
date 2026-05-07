# Kea DHCP — enable service, subnets per zone, static reservations

# Enable Kea DHCP on all VLAN interfaces
resource "restapi_object" "kea_enable" {
  path           = "/api/kea/dhcpv4/set"
  read_path      = "/api/kea/dhcpv4/get"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data = jsonencode({
    dhcpv4 = {
      general = {
        enabled    = "1"
        interfaces = join(",", [
          for name, zone in local.dhcp_zones : local.zone_interface[name]
        ])
      }
    }
  })
  id_attribute = "result"
  object_id    = "kea-enable"
}

resource "restapi_object" "kea_reconfigure" {
  path           = "/api/kea/service/reconfigure"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({})
  id_attribute   = "status"
  object_id      = "kea-reconfigure"

  depends_on = [
    restapi_object.kea_enable,
    opnsense_kea_dhcpv4_subnet.zone,
    opnsense_kea_dhcpv4_reservation.host,
  ]

  lifecycle {
    replace_triggered_by = [restapi_object.kea_enable]
  }
}

resource "opnsense_kea_dhcpv4_subnet" "zone" {
  for_each = local.dhcp_zones

  subnet        = each.value.subnet
  description   = "${each.key} DHCP"
  pools         = ["${each.value.dhcp.range_start}-${each.value.dhcp.range_stop}"]
  routers       = [each.value.gateway]
  domain_name   = local.services.domain
  domain_search = [local.services.domain]
  dns_servers   = [each.value.gateway]
  # NTP not advertised via DHCP — clients use machine.time.servers
  # (public pools). glados ntpd's default `restrict default kod limited`
  # rate-limits LAN clients into a KOD blacklist; not worth fighting.
  ntp_servers   = []

  next_server   = try(each.value.pxe, false) ? each.value.gateway : null
  tftp_server   = try(each.value.pxe, false) ? each.value.gateway : null
  tftp_bootfile = try(each.value.pxe, false) ? local.pxe.bootfile_name : null

  depends_on = [restapi_object.kea_enable]
}

resource "opnsense_kea_dhcpv4_reservation" "host" {
  for_each = {
    for host in local.all_static_hosts : host.name => host
  }

  subnet_id   = opnsense_kea_dhcpv4_subnet.zone[each.value.zone].id
  ip_address  = each.value.ip
  mac_address = each.value.mac
  hostname    = each.value.name
  description = "${each.value.name} (${each.value.zone})"
}
