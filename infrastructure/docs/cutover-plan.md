# Network Segmentation Cutover Plan

## Phase 1: Prepare VyOS ✅
- [x] Install VyOS rolling release on glados (OptiPlex 7060 Micro) via USB
- [x] Configure SSH with ed25519 key (persisted in VyOS config)
- [x] Set temporary IP 192.168.1.5 on flat network
- [x] Verify SSH connectivity from Mac

## Phase 2: Build Ansible Automation ✅
- [x] Create infrastructure/ directory (ansible.cfg, inventory, requirements)
- [x] Write networks.yaml (zones, VLANs, subnets, DHCP, firewall, static hosts)
- [x] Write services.yaml (system, BGP, WireGuard, DNS, NTP, DDNS, doco-cd)
- [x] Write vault.yaml (BWS secret references)
- [x] Write playbook (vyos.yaml) + firewall template (firewall_rule.j2)
- [x] Write run.sh (BWS secret resolution wrapper)
- [x] Create BWS secrets (WG keys, PPPoE, CF token, git PAT)
- [x] Dry-run passes 20/20 tasks with real secrets

## Phase 3: Prepare Container Configs ✅
- [x] Create docker/glados/adguard/ (docker-compose + AdGuardHome.yaml)
- [x] Domain injected at runtime via yq init container (not hardcoded)
- [x] Create .doco-cd.glados.yaml + poll-glados.yaml
- [x] doco-cd configured as VyOS Podman container in playbook

## Phase 4: Prepare Kubernetes Changes (on a branch, no disruption) ✅
- [x] Add kubeconform + ansible-lint pre-commit hooks
- [x] Create branch `feat/network-segmentation`
- [x] Cilium: replace L2 announcements with BGP CRDs (ASN 64513 ↔ 64512), LB pool 10.1.10.41-79
- [x] Cilium: set l2announcements.enabled: false
- [x] Remove fixed LB IPs from envoy, unifi, go2rtc, smtp-relay (Cilium auto-assigns)
- [x] k8s-gateway: fixed IP updated to 10.1.10.41
- [x] Talos: node IPs (.10/.11 control plane, .21-.23 workers), VIP 10.1.10.40 via anchor
- [x] Talos: etcd advertised subnet → 10.1.10.0/24
- [x] Cluster secrets: remove unused ROUTER_IP
- [x] Delete ExternalDNS AdGuard (entire directory + Kustomization)
- [x] Validate: flux-local test 157/157 passed

## Phase 5: Prepare Docker/Donkey Changes (on same branch, no disruption) ✅
- [x] Delete adguard, dnsmasq, chrony (moved to glados)
- [x] Update DNS in all remaining containers: 192.168.1.3 → 10.1.10.1
- [x] Remove AdGuard secret refs from .doco-cd.yaml
- [x] Remove adguard_volume from backup container
- [x] Update power-nap-over: read from networks.yaml, broadcast → 10.1.10.255

## Phase 6: Pre-configure HPE Switch (safe, no disruption)
- [ ] Log into HPE 1820 web UI
- [ ] Create VLANs: 1 (mgmt), 10 (servers), 20 (clients), 30 (iot), 40 (iot-local), 50 (untrusted), 60 (guest)
- [ ] Set glados port as trunk (all VLANs tagged, VLAN 1 untagged PVID)
- [ ] **Leave all other ports unchanged** (untagged VLAN 1 = current flat network still works)
- [ ] Document port-to-VLAN mapping for cutover

## Phase 7: Pre-configure TP-Link Switch (safe, no disruption)
- [ ] Log into TP-Link TL-SG105E web UI
- [ ] Create same VLANs
- [ ] Set uplink port (to HPE) as trunk
- [ ] **Leave all other ports unchanged**

## Phase 8: Apply Ansible to Glados (safe, no disruption)
- [ ] Run: `mise exec -- infrastructure/run.sh` (no --check, apply for real)
- [ ] Verify VyOS config: `show configuration`
- [ ] Verify VLAN interfaces: `show interfaces`
- [ ] Verify BGP config: `show protocols bgp`
- [ ] Verify WireGuard: `show interfaces wireguard`
- [ ] Verify doco-cd container: `show container`
- [ ] Glados is fully configured but idle (no WAN, no trunk traffic yet)

## Phase 9: Cutover (maintenance window, ~30 min)

### Step 1: FritzBox bridge mode
- [ ] Log into fritz.box
- [ ] Internet → Account Information → remove ISP credentials (or placeholder)
- [ ] Enable "Connected network devices are also allowed to establish their own internet connections"
- [ ] Note: FritzBox keeps VDSL sync, passes PPPoE through

### Step 2: Cable change (1 cable move)
- [ ] Disconnect FritzBox LAN cable from HPE switch
- [ ] Plug it into glados USB NIC (WAN)
- [ ] Glados onboard NIC stays on same HPE port (now trunk from Phase 6)

### Step 3: Verify internet through glados
- [ ] From glados console: `ping 8.8.8.8`
- [ ] Verify PPPoE: `show interfaces pppoe pppoe0`
- [ ] Verify public IP: `show interfaces pppoe pppoe0 | grep address`
- [ ] If PPPoE fails: check VLAN tag (835), check FritzBox bridge mode

### Step 4: Move switch ports to target VLANs (HPE web UI)
- [ ] Server ports → VLAN 10 (untagged): elizabeth, donkey, kube-nuc, kube-hp, kube-ceph-01/02/03
- [ ] AP ports → trunk (VLAN 1 untagged + 20/30/40/60 tagged)
- [ ] TP-Link uplink → trunk
- [ ] TP-Link: assign living room device ports to target VLANs
- [ ] Devices get new IPs from glados DHCP (10.1.x.x)

### Step 5: Verify basic connectivity
- [ ] From a client device: check IP is 10.1.20.x
- [ ] DNS resolution: `dig google.com` → works
- [ ] Ad-blocking: blocked domain → NXDOMAIN
- [ ] From glados: `show dhcp server leases`

### Step 6: Reconfigure donkey
- [ ] Donkey gets new IP 10.1.10.3 via DHCP static mapping
- [ ] Verify SSH to donkey (new IP)
- [ ] Remove old containers: adguard, dnsmasq, chrony
- [ ] Update remaining containers dns: references
- [ ] Restart doco-cd on donkey

### Step 7: Migrate Kubernetes cluster
- [ ] Merge branch `feat/network-segmentation` → Flux reconciles
- [ ] Talos nodes get new IPs via DHCP (10.1.10.30-35)
- [ ] Apply Talos config: `talosctl apply-config` for each node
- [ ] Verify kube-vip announces new VIP (10.1.10.40)
- [ ] Verify Cilium BGP on glados: `show bgp summary` → 5 peers
- [ ] Verify BGP routes: `show ip route bgp` → /32 for LB IPs
- [ ] Verify all k8s pods: `kubectl get pods -A`

### Step 8: Configure WiFi
- [ ] UniFi controller: create SSIDs per VLAN
  - Home → VLAN 20 (2.4 + 5 GHz)
  - IoT → VLAN 30 (2.4 GHz)
  - IoT-Local → VLAN 40 (2.4 GHz)
  - Guest → VLAN 60 (2.4 + 5 GHz, client isolation)
- [ ] Reconnect devices to new SSIDs

### Step 9: Verify WireGuard VPN
- [ ] From external network (mobile hotspot):
  - Connect with WireGuard client config
  - Endpoint: vpn.<domain>:51820
  - Verify: `curl https://sonarr.<domain>` → works
- [ ] Verify DDNS on glados: `show dns dynamic status`

## Phase 10: Post-cutover Verification
- [ ] DNS: `dig sonarr.<domain>` → 10.1.10.42
- [ ] Ad-blocking: blocked domain → NXDOMAIN
- [ ] VPN from external network → services accessible
- [ ] VLAN isolation: guest cannot reach servers
- [ ] IoT-Local: no internet access
- [ ] WiFi: each SSID assigns correct VLAN
- [ ] PXE: matchbox on donkey still serves boot (via VLAN 10)
- [ ] BGP: `show bgp summary` → 5 peers established
- [ ] BGP: `show ip route bgp` → /32 routes for LB IPs
- [ ] NTP: Talos nodes sync from glados
- [ ] All k8s workloads healthy
- [ ] Cloudflare Tunnel still works for external services

## Rollback Plan
If something goes critically wrong during cutover:
1. Unplug glados USB NIC from FritzBox
2. Reconnect FritzBox LAN cable to HPE switch
3. HPE switch: revert all ports to untagged VLAN 1
4. FritzBox: restore ISP credentials
5. Network reverts to flat 192.168.1.0/24 — everything back to original

## Follow-up (after stable)
- [ ] Move matchbox from donkey to glados
- [ ] USB 2.5GbE NIC for WAN when FTTH arrives
- [ ] Enable Hubble (Cilium observability)
- [ ] mDNS reflector for cross-VLAN IoT discovery
