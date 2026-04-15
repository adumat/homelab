# VLAN sub-interfaces on the LAN trunk
#
# OPNsense sees vtnet0 (WAN) and vtnet1 (LAN) from VirtIO NICs.
# Each VLAN zone gets a tagged sub-interface on vtnet1.

resource "opnsense_interfaces_vlan" "zone" {
  for_each = local.vlan_zones

  parent      = "vtnet1"
  tag         = each.value.vlan_id
  priority    = 0
  description = each.key
}
