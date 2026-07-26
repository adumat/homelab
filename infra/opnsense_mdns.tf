# mDNS reflector — bridges Bonjour/AirPlay/AirPrint between selected zones.
#
# Plugin os-mdns-repeater is installed manually via OPNsense Plugins UI;
# firmware install isn't a clean fit for declarative config (one-shot,
# requires API polling). Provider has no native resource for it either.

locals {
  # Zones to bridge mDNS between. untrusted/guest deliberately excluded —
  # we don't want guest devices discovering home services.
  mdns_zones = ["clients", "iot", "vpn"]
}

resource "restapi_object" "mdns_repeater_settings" {
  path           = "/api/mdnsrepeater/settings/set"
  read_path      = "/api/mdnsrepeater/settings/get"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"

  data = jsonencode({
    mdnsrepeater = {
      enabled    = "1"
      interfaces = join(",", [for z in local.mdns_zones : local.zone_interface[z]])
    }
  })

  id_attribute = "result"
  object_id    = "mdns-repeater-settings"

  ignore_all_server_changes = true
}

resource "restapi_object" "mdns_repeater_reconfigure" {
  path           = "/api/mdnsrepeater/service/reconfigure"
  create_method  = "POST"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({})
  id_attribute   = "status"
  object_id      = "mdns-repeater-reconfigure"

  ignore_all_server_changes = true

  depends_on = [restapi_object.mdns_repeater_settings]

  lifecycle {
    replace_triggered_by = [restapi_object.mdns_repeater_settings]
  }
}

# Allow mDNS multicast (UDP 5353 -> 224.0.0.251) into glados on each
# participating interface so the daemon can pick the announcements up.
resource "opnsense_firewall_filter" "mdns" {
  for_each = toset(local.mdns_zones)

  sequence    = 4
  description = "Allow mDNS on ${each.key}"
  enabled     = true
  interface   = { interface = [local.zone_interface[each.key]] }

  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "UDP"

    source = {
      net = "any"
    }
    destination = {
      net  = "224.0.0.251"
      port = "5353"
    }
  }
}
