# Firewall — aliases, inter-zone rules, internet control, client isolation
#
# Rule numbering: 100 + src_idx * 100 + dst_idx * 10 + sub_rule
# Same scheme as the original Jinja2 template.

# ── Network group aliases ────────────────────────────────
resource "opnsense_firewall_alias" "zone" {
  for_each = local.zones

  name = upper(each.key)
  type = "network"
  # SERVERS also covers the Cilium LB pool so inter-zone rules
  # targeting "servers" apply to BGP-advertised VIPs too.
  content = each.key == "servers" ? [
    each.value.subnet,
    local.k8s_lb_subnet,
  ] : [each.value.subnet]
  description = "${each.key} network"
  enabled     = true
}

# ── Inter-zone rules ────────────────────────────────────
# Generate all rules from the access matrix in networks.yaml.
# Each policy type (full, none, port-list, range-list) produces
# different rule(s).

locals {
  # Expand inter-zone rules into individual firewall filter entries
  expanded_rules = flatten([
    for rule in local.firewall_rules : (
      rule.policy == "full" ? [{
        key         = "${rule.src}-${rule.dst}"
        sequence    = rule.rule_base
        action      = "pass"
        interface   = rule.src_device
        source_net  = upper(rule.src)
        dest_net    = upper(rule.dst)
        protocol    = "any"
        dest_port   = ""
        description = "${rule.src} -> ${rule.dst}: full"
      }] :
      rule.policy == "none" ? [{
        key         = "${rule.src}-${rule.dst}"
        sequence    = rule.rule_base
        action      = "block"
        interface   = rule.src_device
        source_net  = upper(rule.src)
        dest_net    = upper(rule.dst)
        protocol    = "any"
        dest_port   = ""
        description = "${rule.src} -> ${rule.dst}: blocked"
      }] :
      # Port-based or range-based access lists
      concat(
        [
          for idx, entry in rule.policy : {
            key         = "${rule.src}-${rule.dst}-${idx + 1}"
            sequence    = rule.rule_base + idx + 1
            action      = "pass"
            interface   = rule.src_device
            source_net  = upper(rule.src)
            dest_net    = try(entry.range, upper(rule.dst))
            protocol    = try(entry.proto, "TCP")
            dest_port   = try(tostring(entry.port), "")
            description = "${rule.src} -> ${rule.dst}: ${try(entry.description, "")}"
          }
        ],
        # Drop remaining after specific allows
        [{
          key         = "${rule.src}-${rule.dst}-drop"
          sequence    = rule.rule_base + 9
          action      = "block"
          interface   = rule.src_device
          source_net  = upper(rule.src)
          dest_net    = upper(rule.dst)
          protocol    = "any"
          dest_port   = ""
          description = "${rule.src} -> ${rule.dst}: drop remaining"
        }]
      )
    )
  ])

  rules_map = { for rule in local.expanded_rules : rule.key => rule }
}

# ── Established/related — always first ──────────────────
resource "opnsense_firewall_filter" "established" {
  sequence    = 1
  description = "Allow established/related"
  enabled     = true
  interface   = { interface = concat(
    ["lan", "wan"],
    [for name, zone in local.zones : local.zone_interface[name] if zone.vlan_id != null && zone.vlan_id != 1]
  ) }

  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "any"
    state_type  = "keep state"

    source = {
      net = "any"
    }
    destination = {
      net = "any"
    }
  }
}

# ── Inter-zone rules (from access matrix) ───────────────
resource "opnsense_firewall_filter" "interzone" {
  for_each = local.rules_map

  sequence    = each.value.sequence
  description = each.value.description
  enabled     = true
  interface   = { interface = [each.value.interface] }

  filter = {
    action      = each.value.action
    direction   = "in"
    ip_protocol = "inet"
    protocol    = each.value.protocol

    source = {
      net = each.value.source_net
    }
    destination = {
      net  = each.value.dest_net
      port = each.value.dest_port != "" ? each.value.dest_port : null
    }
  }
}

# ── Allow VPN clients to reach OPNsense services (DNS, etc.) ───
resource "opnsense_firewall_filter" "vpn_to_self" {
  sequence    = 2
  description = "Allow VPN clients to OPNsense services (DNS etc.)"
  enabled     = true
  interface   = { interface = [local.zone_interface["vpn"]] }

  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "any"

    source = {
      net = "VPN"
    }
    destination = {
      net = "(self)"
    }
  }
}

# ── Allow WireGuard inbound on WAN ──────────────────────
resource "opnsense_firewall_filter" "wan_wireguard" {
  sequence    = 2
  description = "Allow WireGuard inbound"
  enabled     = true
  interface   = { interface = ["wan"] }

  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "UDP"

    source = {
      net = "any"
    }
    destination = {
      net  = "(self)"
      port = tostring(local.wireguard.port)
    }
  }
}

# ── Block internet for restricted zones (e.g., iot_local) ─
resource "opnsense_firewall_filter" "block_internet" {
  for_each = local.no_internet_zones

  sequence    = 3 + index(local.zone_names, each.key)
  description = "Block ${each.key} internet"
  enabled     = true
  interface   = { interface = [local.zone_interface[each.key]] }

  filter = {
    action      = "block"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "any"

    source = {
      net = upper(each.key)
    }
    destination = {
      net = "any"
    }
  }
}

# ── Allow internet for zones with internet access ───────
resource "opnsense_firewall_filter" "allow_internet" {
  for_each = {
    for name, zone in local.zones : name => zone
    if try(zone.internet, true) && zone.vlan_id != null
  }

  sequence    = 10 + index(local.zone_names, each.key)
  description = "Allow ${each.key} internet"
  enabled     = true
  interface   = { interface = [local.zone_interface[each.key]] }

  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "any"

    source = {
      net = each.value.subnet
    }
    destination = {
      net = "any"
    }
  }
}

# ── Client isolation (block intra-VLAN traffic) ─────────
resource "opnsense_firewall_filter" "client_isolation" {
  for_each = local.isolation_zones

  sequence    = 950 + index(local.zone_names, each.key)
  description = "Client isolation: ${each.key}"
  enabled     = true
  interface   = { interface = [local.zone_interface[each.key]] }

  filter = {
    action      = "block"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "any"

    source = {
      net = upper(each.key)
    }
    destination = {
      net = upper(each.key)
    }
  }
}
