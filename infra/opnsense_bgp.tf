# BGP peering — OPNsense (FRR/Quagga) <-> Cilium
#
# Native provider handles neighbors. General FRR + BGP enable
# and AS/router-id settings use restapi (not in native provider).

# Enable FRR service
resource "restapi_object" "frr_general" {
  path           = "/api/quagga/general/set"
  read_path      = "/api/quagga/general/get"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({ general = { enabled = "1" } })
  id_attribute   = "result"
  object_id      = "frr-general"
}

# Enable BGP + set AS number and router-id
resource "restapi_object" "bgp_settings" {
  path           = "/api/quagga/bgp/set"
  read_path      = "/api/quagga/bgp/get"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data = jsonencode({
    bgp = {
      enabled  = "1"
      asnumber = tostring(local.bgp.local_as)
      routerid = local.bgp.router_id
    }
  })
  id_attribute = "result"
  object_id    = "bgp-settings"

  depends_on = [restapi_object.frr_general]
}

# Reconfigure FRR after changes
resource "restapi_object" "frr_reconfigure" {
  path           = "/api/quagga/service/reconfigure"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({})
  id_attribute   = "status"
  object_id      = "frr-reconfigure"

  depends_on = [
    restapi_object.bgp_settings,
    opnsense_quagga_bgp_neighbor.cilium,
  ]

  lifecycle {
    replace_triggered_by = [
      restapi_object.frr_general,
      restapi_object.bgp_settings,
    ]
  }
}

# BGP neighbors via native provider
resource "opnsense_quagga_bgp_neighbor" "cilium" {
  for_each = {
    for n in local.bgp.neighbors : n.description => n
  }

  enabled     = true
  peer_ip     = each.value.ip
  remote_as   = each.value.remote_as
  description = each.value.description

  depends_on = [restapi_object.bgp_settings]
}
