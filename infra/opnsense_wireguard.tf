# WireGuard VPN — server + peers

# Enable WireGuard service
resource "restapi_object" "wireguard_enable" {
  path           = "/api/wireguard/general/set"
  read_path      = "/api/wireguard/general/get"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({ general = { enabled = "1" } })
  id_attribute   = "result"
  object_id      = "wireguard-enable"

  ignore_all_server_changes = true
}

resource "restapi_object" "wireguard_reconfigure" {
  path           = "/api/wireguard/service/reconfigure"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({})
  id_attribute   = "result"
  object_id      = "wireguard-reconfigure"

  ignore_all_server_changes = true

  depends_on = [
    restapi_object.wireguard_enable,
    opnsense_wireguard_server.wg0,
    opnsense_wireguard_client.peer,
  ]

  lifecycle {
    replace_triggered_by = [restapi_object.wireguard_enable]
  }
}

resource "opnsense_wireguard_server" "wg0" {
  name           = "wg0"
  port           = local.wireguard.port
  tunnel_address = [local.wireguard.address]
  private_key    = var.wg_private_key
  public_key     = var.wg_public_key
  # 1380 leaves room for WG's ~60 bytes of overhead within a 1500 underlay
  # while staying clear of intermediate path-MTU dips. Chiaki video streams
  # were silently dropped at the default 1420 (PMTU black hole, no ICMP
  # needs-frag delivered back to the client).
  mtu     = 1380
  peers   = [for peer in opnsense_wireguard_client.peer : peer.id]
  enabled = true

  depends_on = [restapi_object.wireguard_enable]
}

resource "opnsense_wireguard_client" "peer" {
  for_each = {
    for peer in local.wireguard.peers : peer.name => peer
  }

  name           = each.value.name
  public_key     = var.wg_peer_public_keys[each.key]
  tunnel_address = [each.value.allowed_ips]
  keep_alive     = each.value.persistent_keepalive
  enabled        = true

  depends_on = [restapi_object.wireguard_enable]
}
