# UPnP / IGD for PS5 Remote Play (manual setup)

Enables the PS5 (and other `clients` VLAN devices) to open inbound ports on
glados automatically, fixing PS5 Remote Play "connection error" and strict NAT
type. **Limited to the `clients` VLAN (10.1.20.0/24) only.**

## Why this is NOT in Terraform

UPnP can't be managed declaratively on this stack:

- The `browningluke/opnsense` provider has **no UPnP resource** (verified up to
  v0.24.0).
- The `os-upnp` plugin is **legacy**: it has no MVC API (`/api/upnp/...` returns
  *Endpoint not found*), only the `services_upnp.php` web form, storing config
  under `config['installedpackages']['miniupnpd']`. The `restapi` provider only
  drives modern `/api/.../settings/set` endpoints, so it can't touch it.

Same situation as `os-mdns-repeater`: install + configure by hand, document here.

## Background: double NAT

```
Internet ──PPPoE──> FritzBox 192.168.1.1 ──"exposed host"──> glados WAN 192.168.1.200
                                                              └─ clients VLAN20 ─> PS5 10.1.20.31 (LAN) / .30 (WiFi)
```

- **No CGNAT** — FritzBox external IP == public IP (verified via IGD
  `GetExternalIPAddress`). Port traversal is possible.
- glados WAN (`192.168.1.200`) is **private**, so miniupnpd would advertise a
  private external IP to the PS5. Fixed with **STUN** (below) so it discovers the
  real public IP.

## Setup

### 1. Install the plugin

System → Firmware → Plugins → install **`os-upnp`**.

### 2. Verify FritzBox forwards inbound to glados

FritzBox → Internet → Permit Access → **Exposed Host = 192.168.1.200**
(forwards all inbound ports to glados WAN). Without this, inbound Remote Play
never reaches OPNsense.

### 3. Configure UPnP — Services → UPnP/IGD → Settings

| Field | Value |
|-------|-------|
| Enable service | ✅ |
| Enable UPnP Port Mapping | ✅ (PS5 uses UPnP IGD) |
| Enable NAT-PMP | ✅ (optional, harmless) |
| Enable UPnP IGD protocol | ✅ (PS5 uses IGD) |
| Enable PCP/NAT-PMP | optional (PS5 doesn't need it) |
| External interface | **WAN** |
| Internal interfaces | **clients** (VLAN 20) — *only this one* |
| STUN server / port | `stun.l.google.com` / `19302` (so it learns the real public IP behind the double NAT) |
| Allow third-party mapping | **Disabled** (PS5 only maps its own ports) |
| UPnP IGD compatibility | IGDv1 (IPv4 only) |

> STUN is preferred over "Override external IPv4" because the public IP may be
> dynamic — STUN re-discovers it automatically.

### 4. ACL — limit to the clients subnet

Under **Access Control List**:

- **Default deny** → ✅ (denies anything not explicitly allowed)
- **ACL entry 1** → `allow 1024-65535 10.1.20.0/24 1024-65535`

(miniupnpd ACL syntax: `<action> <ext ports> <int CIDR> <int ports>`.) With
*Default deny* on, the single `allow` is enough — everything else is blocked.
The interface restriction (step 3) already scopes requests to VLAN 20; the ACL
is defense-in-depth so only `10.1.20.0/24` hosts can ever create mappings.

### 5. Verify

- PS5 → Settings → Network → Connection Status → **Test Internet Connection** →
  NAT Type should be **2** (not 3).
- Services → UPnP/IGD → **Active Maps** shows the PS5's mappings.
- Test Remote Play from outside the LAN (mobile data).

## Optional: static-port outbound NAT (redundant once UPnP works)

Not needed if UPnP is active (the PS5 opens its own ports). Cannot be automated
here — the provider doesn't expose `staticnatport` and `restapi_object` can't do
the rule CRUD. If ever wanted, add **manually** in Firewall → NAT → Outbound
(mode must stay Manual/Hybrid), **above** the `10.1.0.0/16` masquerade rule:

| Field | Value |
|-------|-------|
| Interface | WAN |
| Source | `10.1.20.30` and `10.1.20.31` (PS5) |
| Translation / target | Interface address (`wanip`) |
| **Static-port** | ✅ |
