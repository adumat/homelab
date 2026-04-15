output "vlan_summary" {
  description = "VLAN zones configured"
  value = {
    for name, zone in local.vlan_zones : name => {
      vlan_id = zone.vlan_id
      subnet  = zone.subnet
      gateway = zone.gateway
    }
  }
}

output "bgp_neighbors" {
  description = "BGP peer summary"
  value = [
    for n in local.bgp.neighbors : "${n.description} (${n.ip}) AS${n.remote_as}"
  ]
}

output "static_hosts_count" {
  description = "Total DHCP static host mappings"
  value       = length(local.all_static_hosts)
}

output "firewall_rules_count" {
  description = "Total inter-zone firewall rules"
  value       = length(local.firewall_rules)
}
