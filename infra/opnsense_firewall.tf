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

# ── Established/related ─────────────────────────────────
# sequence 2 (was 1) so the servers→k8s-LB sloppy rule can sit at sequence 1 and
# win for VIP-bound traffic; still ahead of allow_internet and the inter-zone rules.
resource "opnsense_firewall_filter" "established" {
  sequence    = 2
  description = "Allow established/related"
  enabled     = true
  interface = { interface = concat(
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
    # NON-internal only: internal destinations fall through to the inter-zone
    # rules (matrix). Without this, "-> any" would pass internal traffic wholesale
    # and defeat segmentation the same way the blanket 'established' rule does.
    destination = {
      net    = local.internal_supernet
      invert = true
    }
  }
}

# ── Per-zone DNS/NTP to the firewall itself ─────────────
# DHCP hands each zone its gateway (OPNsense) as DNS + NTP server, so every zone
# needs to reach (self):53 and :123. This is the traffic that today rides ONLY the
# blanket 'established' rule; making it explicit is what lets that rule be removed
# without breaking name resolution / time sync network-wide.
resource "opnsense_firewall_filter" "self_dns" {
  for_each = local.dhcp_zones

  sequence    = 4
  description = "${each.key} -> firewall DNS"
  enabled     = true
  interface   = { interface = [local.zone_interface[each.key]] }

  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "TCP/UDP"

    source = {
      net = each.value.subnet
    }
    destination = {
      net  = "(self)"
      port = "53"
    }
  }
}

resource "opnsense_firewall_filter" "self_ntp" {
  for_each = local.dhcp_zones

  sequence    = 5
  description = "${each.key} -> firewall NTP"
  enabled     = true
  interface   = { interface = [local.zone_interface[each.key]] }

  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "UDP"

    source = {
      net = each.value.subnet
    }
    destination = {
      net  = "(self)"
      port = "123"
    }
  }
}

# ── servers → k8s LB VIPs: sloppy state (asymmetric routing) ──
# Cilium advertises the LB VIPs (k8s_lb_subnet) via BGP with the k8s nodes as
# next-hop. The nodes sit in the servers subnet, so a servers-zone host's request
# to a VIP goes out through OPNsense (different subnet → default gw) but the reply
# comes straight back node→host on the shared L2, bypassing OPNsense. The firewall
# never sees the SYN-ACK, so the keep-state entry stays half-open (CLOSED:SYN_SENT)
# and is reaped at tcp.opening (~30s), tearing long-lived TCP (e.g. MQTT) every
# ~30-60s. Sloppy state drops seq/handshake tracking so it tolerates the asymmetry.
# Must be evaluated BEFORE the blanket "established" rule (any→any keep state,
# quick), which otherwise grabs the SYN first and creates a strict keep-state.
# sequence 1 (established bumped to 2) places it first, so VIP-bound traffic gets
# sloppy state while everything else still falls through to established / allow_internet.
resource "opnsense_firewall_filter" "servers_to_lb_sloppy" {
  sequence    = 1
  description = "servers -> k8s LB VIPs: sloppy state (asymmetric BGP VIP routing)"
  enabled     = true
  interface   = { interface = [local.zone_interface["servers"]] }

  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "any"

    source = {
      net = local.zones["servers"].subnet
    }
    destination = {
      net = local.k8s_lb_subnet
    }
  }

  # sloppy = don't track TCP sequence numbers, so the half-seen (asymmetric)
  # flow is not reaped as a stuck half-open state.
  stateful_firewall = {
    type = "sloppy"
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
