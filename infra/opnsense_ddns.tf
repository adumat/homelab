# Dynamic DNS — Cloudflare

resource "restapi_object" "ddns_cloudflare" {
  path           = "/api/dyndns/accounts/add_item"
  read_path      = "/api/dyndns/accounts/get_item/{id}"
  update_path    = "/api/dyndns/accounts/set_item/{id}"
  destroy_path   = "/api/dyndns/accounts/del_item/{id}"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"

  data = jsonencode({
    account = {
      enabled     = "1"
      description = "Cloudflare DDNS"
      service     = "cloudflare"
      username    = "token"
      password    = var.cloudflare_api_token
      zone        = var.base_domain
      hostnames   = "vpn.${var.base_domain}"
      interface   = "wan"
      checkip     = "web_akamai"
      force_ssl   = "1"
      ttl         = "300"
    }
  })

  id_attribute = "uuid"
}

resource "restapi_object" "ddns_reconfigure" {
  path           = "/api/dyndns/service/reconfigure"
  create_method  = "POST"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({})
  id_attribute   = "status"
  object_id      = "ddns-reconfigure"

  depends_on = [restapi_object.ddns_cloudflare]

  lifecycle {
    replace_triggered_by = [restapi_object.ddns_cloudflare]
  }
}
