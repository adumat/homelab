# VLAN sub-interfaces on the LAN trunk
#
# OPNsense sees vtnet0 (LAN) and vtnet1 (WAN) from VirtIO NICs.
# Each VLAN zone gets a tagged sub-interface on vtnet0.
# VLAN 1 (untrusted) uses untagged LAN directly — no sub-interface needed.

resource "opnsense_interfaces_vlan" "zone" {
  for_each = {
    for name, zone in local.vlan_zones : name => zone
    if zone.vlan_id != 1
  }

  parent      = local.networks.lan_interface
  tag         = each.value.vlan_id
  priority    = 0
  device      = "vlan0.${each.value.vlan_id}"
  description = lookup({
    servers   = "SRV"
    clients   = "CLI"
    iot       = "IOT"
    iot_local = "IOTL"
    guest     = "GST"
  }, each.key, each.key)
}
