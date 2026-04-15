# Unbound DNS — forwarding, host overrides
#
# No AdGuard — Unbound handles everything natively.
# Blocklists configured via OPNsense web UI (DNSBL plugin).

# Forward base_domain to k8s-gateway (Cilium LB)
resource "opnsense_unbound_forward" "k8s_gateway" {
  domain    = var.base_domain
  server_ip = "10.1.10.41"
  enabled   = true
}

# Host overrides from DHCP static hosts (hostname.lan -> IP)
resource "opnsense_unbound_host_override" "static_host" {
  for_each = {
    for host in local.all_static_hosts : host.name => host
  }

  hostname    = each.value.name
  domain      = local.services.domain
  server      = each.value.ip
  description = "${each.value.name} (${each.value.zone})"
  enabled     = true
}

# Extra DNS records from networks.yaml
resource "opnsense_unbound_host_override" "extra" {
  for_each = merge([
    for domain, records in local.dns_records : {
      for record in records :
      "${record.name}.${domain}" => {
        hostname = record.name
        domain   = domain
        ip       = record.ip
      }
    }
  ]...)

  hostname    = each.value.hostname
  domain      = each.value.domain
  server      = each.value.ip
  description = "Extra DNS record"
  enabled     = true
}
