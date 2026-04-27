# Unbound DNS — forwarding, host overrides
#
# No AdGuard — Unbound handles everything natively.
# Blocklists configured via OPNsense web UI (DNSBL plugin).

# Domains forwarded to k8s-gateway (Cilium LB).
#
# TODO: switch to the native resource below once browningluke/opnsense is fixed.
# The provider's opnsense_unbound_forward calls OPNsense's /addDot endpoint under
# the hood (via opnsense-go client lib), which always sets type=dot and emits
# `forward-tls-upstream: yes`. k8s-gateway serves plain UDP/53 (no TLS), so the
# query fails with SERVFAIL. Upstream bug:
# https://github.com/browningluke/opnsense-go/blob/main/pkg/unbound/forward.go
#
# resource "opnsense_unbound_forward" "k8s_gateway" {
#   for_each  = toset(local.k8s_gateway_forward_domains)
#   domain    = each.value
#   server_ip = local.k8s_gateway_ip
#   enabled   = true
# }
resource "restapi_object" "unbound_forward_k8s_gateway" {
  for_each = toset(local.k8s_gateway_forward_domains)

  path           = "/api/unbound/settings/addForward"
  read_path      = "/api/unbound/settings/getForward/{id}"
  update_path    = "/api/unbound/settings/setForward/{id}"
  destroy_path   = "/api/unbound/settings/delForward/{id}"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"

  data = jsonencode({
    dot = {
      enabled              = "1"
      domain               = each.value
      server               = local.k8s_gateway_ip
      port                 = "53"
      description          = "k8s-gateway (${each.value})"
      forward_tcp_upstream = "0"
      forward_first        = "0"
      verify               = ""
    }
  })

  id_attribute = "uuid"
}

# ── DNS blocklists (replaces AdGuard) ───────────────────
# OPNsense Unbound DNSBL with curated lists. Add more by appending to `type`.
resource "restapi_object" "unbound_dnsbl" {
  path           = "/api/unbound/settings/set"
  read_path      = "/api/unbound/settings/get"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"

  data = jsonencode({
    unbound = {
      dnsbl = {
        enabled    = "1"
        safesearch = "0"
        type       = "aa,ag" # AdAway + AdGuard List
        nxdomain   = "0"
        address    = ""
      }
    }
  })

  id_attribute = "result"
  object_id    = "unbound-dnsbl"
}

resource "restapi_object" "unbound_reconfigure" {
  path           = "/api/unbound/service/reconfigure"
  create_method  = "POST"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({})
  id_attribute   = "status"
  object_id      = "unbound-reconfigure"

  depends_on = [
    restapi_object.unbound_forward_k8s_gateway,
    restapi_object.unbound_dnsbl,
  ]

  lifecycle {
    replace_triggered_by = [
      restapi_object.unbound_forward_k8s_gateway,
      restapi_object.unbound_dnsbl,
    ]
  }
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
