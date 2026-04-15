# Outbound NAT — masquerade all internal traffic to WAN

resource "opnsense_firewall_nat" "masquerade" {
  enabled     = true
  interface   = "wan"
  ip_protocol = "inet"
  protocol    = "any"
  sequence    = 1
  description = "Outbound NAT masquerade"

  source = {
    net = "10.1.0.0/16"
  }

  destination = {
    net = "any"
  }

  target = {
    ip = "wanip" # OPNsense shorthand for WAN interface address (masquerade)
  }
}
