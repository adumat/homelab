#!/usr/bin/env python3
import base64
import json
import subprocess
import time
import socket
import yaml
import requests
import os
import traceback
from datetime import datetime
from enum import Enum, auto
from typing import List, Dict, Optional, Tuple


# =============================================================================
# Enums
# =============================================================================

class AppState(Enum):
    NORMAL = auto()
    POWER_FAILURE = auto()
    GRACE_PERIOD = auto()
    WAITING_SHUTDOWN = auto()
    READY_TO_WAKE = auto()
    WAKING = auto()


class NodeStatus(Enum):
    ONLINE = auto()
    SHUTTING_DOWN = auto()
    UNREACHABLE = auto()


class UPSPowerStatus(Enum):
    ONLINE = "OL"
    ON_BATTERY = "OB"
    UNKNOWN = "UNKNOWN"


# =============================================================================
# PushoverNotifier
# =============================================================================

class PushoverNotifier:
    """Handle Pushover notifications"""

    def __init__(self, config: Dict):
        self.enabled = config.get('enabled', False)
        self.api_token = config.get('api_token', '')
        self.user_key = config.get('user_key', '')
        self.priority = config.get('priority', 0)
        self.sound = config.get('sound', 'pushover')
        self.notify_on = config.get('notify_on', {})
        self.api_url = "https://api.pushover.net/1/messages.json"

        if self.enabled and (not self.api_token or not self.user_key):
            print("WARNING: Pushover enabled but credentials missing!")
            self.enabled = False

    def send(self, title: str, message: str, priority: Optional[int] = None, sound: Optional[str] = None):
        if not self.enabled:
            return False
        try:
            payload = {
                "token": self.api_token,
                "user": self.user_key,
                "title": title,
                "message": message,
                "priority": priority if priority is not None else self.priority,
                "sound": sound if sound is not None else self.sound,
                "timestamp": int(time.time())
            }
            response = requests.post(self.api_url, data=payload, timeout=10)
            if response.status_code == 200:
                print(f"  Pushover notification sent: {title}")
                return True
            else:
                print(f"  Pushover notification failed: {response.status_code} - {response.text}")
                return False
        except Exception as e:
            print(f"  Error sending Pushover notification: {e}")
            return False

    def notify_power_failure(self, status: str, charge: float):
        if not self.notify_on.get('power_failure', True):
            return
        self.send("UPS On Battery", f"Power failure detected.\n\nUPS Status: {status}\nBattery: {charge}%",
                   priority=1, sound="siren")

    def notify_servers_down(self, offline_servers: List[Dict], total_servers: int):
        if not self.notify_on.get('servers_down', True):
            return
        server_list = "\n".join([f"- {s['name']} ({s['ip']})" for s in offline_servers])
        self.send(f"Homelab: {len(offline_servers)}/{total_servers} Servers Down",
                   f"The following servers are offline:\n\n{server_list}",
                   priority=1, sound="falling")

    def notify_ups_not_ready(self, status: str, charge: float):
        if not self.notify_on.get('ups_not_ready', True):
            return
        self.send("UPS Not Ready", f"Cannot start recovery.\n\nUPS Status: {status}\nBattery: {charge}%",
                   priority=1, sound="alien")

    def notify_ups_restored(self, charge: float):
        if not self.notify_on.get('ups_restored', True):
            return
        self.send("UPS Restored", f"UPS is back online.\n\nBattery: {charge}%\nStarting recovery sequence...",
                   priority=0, sound="magic")

    def notify_shutdown_in_progress(self, nodes: List[str]):
        if not self.notify_on.get('shutdown_in_progress', True):
            return
        node_list = "\n".join([f"- {n}" for n in nodes])
        self.send("Nodes Shutting Down", f"Shutdown sequence detected:\n\n{node_list}",
                   priority=0)

    def notify_all_nodes_off(self):
        if not self.notify_on.get('all_nodes_off', True):
            return
        self.send("All Nodes Powered Off",
                   "All monitored servers are confirmed off.\nWaiting for UPS readiness before wake-up.",
                   priority=0)

    def notify_recovery_started(self, groups_to_recover: List[str]):
        if not self.notify_on.get('recovery_started', True):
            return
        groups = "\n".join([f"- {g}" for g in groups_to_recover])
        self.send("Recovery Started", f"Starting server recovery sequence.\n\nGroups:\n{groups}", priority=0)

    def notify_recovery_completed(self, woken_servers: int):
        if not self.notify_on.get('recovery_completed', True):
            return
        self.send("Recovery Completed",
                   f"Server recovery sequence completed.\n\n{woken_servers} server(s) sent WOL packets.",
                   priority=0, sound="magic")

    def notify_crash_detected(self, offline_servers: List[Dict], auto_wake: bool):
        if not self.notify_on.get('crash_detected', True):
            return
        server_list = "\n".join([f"- {s['name']} ({s['ip']})" for s in offline_servers])
        action = "Auto-WOL enabled, attempting recovery." if auto_wake else "Auto-WOL disabled, manual intervention required."
        self.send("Server Crash Detected",
                   f"Servers down (no power event):\n\n{server_list}\n\n{action}",
                   priority=1, sound="falling")

    def notify_stuck_node(self, node_name: str):
        if not self.notify_on.get('errors', True):
            return
        self.send("Stuck Node Warning",
                   f"Node '{node_name}' failed to power off during shutdown sequence. Proceeding with wake-up.",
                   priority=1, sound="alien")

    def notify_error(self, error_msg: str):
        if not self.notify_on.get('errors', True):
            return
        self.send("Homelab Monitor Error", f"An error occurred:\n\n{error_msg}",
                   priority=1, sound="siren")


# =============================================================================
# NUTMonitor
# =============================================================================

class NUTMonitor:
    """Monitor UPS status via NUT network protocol"""

    def __init__(self, config: Dict):
        self.host = config['host']
        self.port = config.get('port', 3493)
        self.ups_name = config['name']
        self.username = config.get('username')
        self.password = os.getenv('NUT_MONITOR_PASSWORD', '')
        self.min_charge = config['min_charge']
        self._consecutive_failures = 0

    def query_raw(self) -> Optional[Dict[str, str]]:
        """Query all UPS variables via NUT protocol"""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.settimeout(5)
            sock.connect((self.host, self.port))

            def send_cmd(cmd: str) -> str:
                sock.sendall(f"{cmd}\n".encode())
                response = b""
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    response += chunk
                    if b"\n" in chunk:
                        break
                return response.decode().strip()

            def send_cmd_multiline(cmd: str) -> str:
                sock.sendall(f"{cmd}\n".encode())
                response = b""
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    response += chunk
                    if b"END LIST VAR" in response or b"ERR" in response:
                        break
                return response.decode()

            if self.username and self.password:
                resp = send_cmd(f"USERNAME {self.username}")
                if resp.startswith("ERR"):
                    print(f"NUT auth error (USERNAME): {resp}")
                    return None
                resp = send_cmd(f"PASSWORD {self.password}")
                if resp.startswith("ERR"):
                    print(f"NUT auth error (PASSWORD): {resp}")
                    return None

            raw = send_cmd_multiline(f"LIST VAR {self.ups_name}")
            send_cmd("LOGOUT")

            status = {}
            for line in raw.split('\n'):
                if line.startswith('VAR '):
                    parts = line.split('"')
                    if len(parts) >= 2:
                        var_name = line.split()[2]
                        var_value = parts[1]
                        status[var_name] = var_value
            return status
        except Exception as e:
            print(f"Exception querying UPS: {e}")
            return None
        finally:
            sock.close()

    def get_status(self) -> Tuple[UPSPowerStatus, float, str]:
        """Return parsed (power_status, battery_charge, raw_status_string)"""
        raw = self.query_raw()
        if not raw:
            self._consecutive_failures += 1
            return UPSPowerStatus.UNKNOWN, 0.0, "UNREACHABLE"

        self._consecutive_failures = 0
        status_str = raw.get('ups.status', 'UNKNOWN')
        try:
            charge = float(raw.get('battery.charge', '0'))
        except ValueError:
            charge = 0.0

        if 'OB' in status_str:
            return UPSPowerStatus.ON_BATTERY, charge, status_str
        elif 'OL' in status_str:
            return UPSPowerStatus.ONLINE, charge, status_str
        return UPSPowerStatus.UNKNOWN, charge, status_str

    def is_ready_for_wake(self) -> Tuple[bool, float, str]:
        """Check if UPS is online with sufficient charge. Returns (ready, charge, status_str)"""
        power_status, charge, status_str = self.get_status()
        is_ready = power_status == UPSPowerStatus.ONLINE and charge >= self.min_charge
        return is_ready, charge, status_str

    @property
    def consecutive_failures(self) -> int:
        return self._consecutive_failures


# =============================================================================
# TalosMonitor
# =============================================================================

class TalosMonitor:
    """Monitor Talos node machine stages via talosctl"""

    def __init__(self, config: Dict):
        self.enabled = config.get('enabled', False)
        self.talosctl_path = config.get('talosctl_path', 'talosctl')
        self._talosconfig_path = None
        self._available = False

        if self.enabled:
            self._setup_talosconfig()
            self._check_available()

    def _setup_talosconfig(self):
        """Decode TALOSCONFIG env var (base64) and write to temp file"""
        talosconfig_b64 = os.getenv('TALOSCONFIG', '')
        if not talosconfig_b64:
            print("WARNING: TALOSCONFIG env var not set, Talos monitoring disabled")
            self.enabled = False
            return

        try:
            talosconfig_content = base64.b64decode(talosconfig_b64)
            path = '/tmp/talosconfig'
            with open(path, 'wb') as f:
                f.write(talosconfig_content)
            os.chmod(path, 0o600)
            self._talosconfig_path = path
            print(f"Talosconfig decoded and written to {path}")
        except Exception as e:
            print(f"WARNING: Failed to decode TALOSCONFIG: {e}")
            self.enabled = False

    def _check_available(self):
        """Check if talosctl binary is available"""
        if not self.enabled:
            return
        try:
            result = subprocess.run(
                [self.talosctl_path, 'version', '--client'],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                self._available = True
                version_line = result.stdout.strip().split('\n')[0] if result.stdout else 'unknown'
                print(f"talosctl available: {version_line}")
            else:
                print(f"WARNING: talosctl check failed: {result.stderr}")
                self._available = False
        except (FileNotFoundError, subprocess.TimeoutExpired) as e:
            print(f"WARNING: talosctl not available: {e}")
            self._available = False

    @property
    def is_available(self) -> bool:
        return self.enabled and self._available and self._talosconfig_path is not None

    def get_machine_stage(self, ip: str) -> Optional[str]:
        """Query Talos API for machine stage. Returns stage string or None if unreachable."""
        if not self.is_available:
            return None
        try:
            result = subprocess.run(
                [self.talosctl_path, '--talosconfig', self._talosconfig_path,
                 '-n', ip, 'get', 'machinestatus', '-o', 'json'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0 and result.stdout.strip():
                data = json.loads(result.stdout)
                return data.get('spec', {}).get('stage', None)
        except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception):
            pass
        return None


# =============================================================================
# PowerNapOver - State Machine
# =============================================================================

class PowerNapOver:
    def __init__(self, config_path: str = '/app/config/config.yaml'):
        with open(config_path, 'r') as f:
            self.config = yaml.safe_load(f)

        self.server_groups = self.config['server_groups']
        for group in self.server_groups:
            if group.get('servers') is None:
                group['servers'] = []
        self.server_groups.sort(key=lambda x: x['priority'])

        self.ups_config = self.config['ups']
        self.monitoring = self.config['monitoring']
        self.network_config = self.config.get('network', {})

        # Initialize components
        self.nut = NUTMonitor(self.ups_config)
        self.talos = TalosMonitor(self.config.get('talos', {}))

        pushover_config = self.config.get('pushover', {})
        if os.getenv('PUSHOVER_TOKEN'):
            pushover_config['api_token'] = os.getenv('PUSHOVER_TOKEN')
        if os.getenv('PUSHOVER_USER'):
            pushover_config['user_key'] = os.getenv('PUSHOVER_USER')
        self.notifier = PushoverNotifier(pushover_config)

        # State machine
        self._state = AppState.NORMAL
        self._state_entered_at = time.time()
        self._ob_detected_at: Optional[float] = None
        self._last_ping_sweep: float = 0
        self._notified_power_failure = False
        self._notified_shutdown = False
        self._notified_all_off = False
        self._notified_crash = False

        # Per-server tracking
        self._server_status: Dict[str, NodeStatus] = {}
        self._unreachable_since: Dict[str, float] = {}
        self._all_servers = self._collect_all_servers()

    def _collect_all_servers(self) -> List[Dict]:
        """Flatten all servers from all groups"""
        servers = []
        for group in self.server_groups:
            for server in group['servers']:
                servers.append(server)
                self._server_status[server['name']] = NodeStatus.ONLINE
        return servers

    # -------------------------------------------------------------------------
    # State transitions
    # -------------------------------------------------------------------------

    def _transition(self, new_state: AppState):
        old = self._state
        self._state = new_state
        self._state_entered_at = time.time()
        print(f"[STATE] {old.name} -> {new_state.name}")

        # Reset per-state notification flags
        if new_state == AppState.POWER_FAILURE:
            self._notified_power_failure = False
            self._notified_shutdown = False
            self._notified_all_off = False
        elif new_state == AppState.NORMAL:
            self._notified_crash = False

    def _time_in_state(self) -> float:
        return time.time() - self._state_entered_at

    def get_poll_interval(self) -> float:
        intervals = {
            AppState.NORMAL: self.monitoring.get('nut_poll_interval', 30),
            AppState.POWER_FAILURE: 10.0,
            AppState.GRACE_PERIOD: 10.0,
            AppState.WAITING_SHUTDOWN: 15.0,
            AppState.READY_TO_WAKE: 30.0,
            AppState.WAKING: 30.0,
        }
        return intervals[self._state]

    # -------------------------------------------------------------------------
    # Server monitoring helpers
    # -------------------------------------------------------------------------

    def _ping(self, ip: str) -> bool:
        timeout = self.monitoring.get('ping_timeout', 2)
        try:
            result = subprocess.run(
                ['ping', '-c', '1', '-W', str(timeout), ip],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            return result.returncode == 0
        except Exception:
            return False

    def _check_server_status(self, server: Dict) -> NodeStatus:
        """Check a single server's status using ping + optional Talos API"""
        is_pingable = self._ping(server['ip'])

        if is_pingable:
            if server.get('type') == 'talos':
                stage = self.talos.get_machine_stage(server['ip'])
                if stage and 'shutting' in stage.lower():
                    return NodeStatus.SHUTTING_DOWN
            return NodeStatus.ONLINE

        # Not pingable - check Talos API as fallback
        if server.get('type') == 'talos':
            stage = self.talos.get_machine_stage(server['ip'])
            if stage is not None:
                if 'shutting' in stage.lower():
                    return NodeStatus.SHUTTING_DOWN

        return NodeStatus.UNREACHABLE

    def _update_all_server_statuses(self):
        """Poll all servers and update their tracked status"""
        for server in self._all_servers:
            name = server['name']
            status = self._check_server_status(server)
            old_status = self._server_status.get(name)
            self._server_status[name] = status

            if status == NodeStatus.UNREACHABLE:
                if name not in self._unreachable_since:
                    self._unreachable_since[name] = time.time()
            else:
                self._unreachable_since.pop(name, None)

            if status != old_status:
                print(f"  {name}: {old_status.name if old_status else '?'} -> {status.name}")

    def _all_servers_online(self) -> bool:
        return all(s == NodeStatus.ONLINE for s in self._server_status.values())

    def _all_servers_off(self) -> bool:
        """All servers confirmed off (unreachable for > 30s)"""
        confirm_time = 30
        now = time.time()
        for server in self._all_servers:
            name = server['name']
            status = self._server_status.get(name, NodeStatus.ONLINE)
            if status == NodeStatus.ONLINE:
                return False
            if status == NodeStatus.SHUTTING_DOWN:
                return False
            since = self._unreachable_since.get(name)
            if since is None or (now - since) < confirm_time:
                return False
        return True

    def _get_offline_servers(self) -> List[Dict]:
        return [s for s in self._all_servers if self._server_status.get(s['name']) != NodeStatus.ONLINE]

    def _get_shutting_down_servers(self) -> List[str]:
        return [name for name, status in self._server_status.items() if status == NodeStatus.SHUTTING_DOWN]

    # -------------------------------------------------------------------------
    # WOL helpers
    # -------------------------------------------------------------------------

    def _send_wol(self, mac_address: str):
        mac = mac_address.replace(':', '').replace('-', '')
        magic_packet = bytes.fromhex('FF' * 6 + mac * 16)
        broadcast_ip = self.network_config.get('broadcast_ip', '255.255.255.255')
        port = self.network_config.get('wol_port', 9)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(magic_packet, (broadcast_ip, port))
        sock.close()

    def _wake_server(self, server: Dict):
        retry_count = self.monitoring.get('wol_retry_count', 3)
        retry_delay = self.monitoring.get('wol_retry_delay', 1)
        print(f"    Waking {server['name']} ({server['mac']})")
        for i in range(retry_count):
            self._send_wol(server['mac'])
            if i < retry_count - 1:
                time.sleep(retry_delay)
        print(f"    WOL packets sent ({retry_count}x)")

    # -------------------------------------------------------------------------
    # State handlers
    # -------------------------------------------------------------------------

    def _handle_normal(self):
        # Check UPS
        power_status, charge, status_str = self.nut.get_status()
        now = time.time()

        if power_status == UPSPowerStatus.ON_BATTERY:
            print(f"UPS on battery! Status: {status_str}, Charge: {charge}%")
            self._ob_detected_at = now
            self.notifier.notify_power_failure(status_str, charge)
            self._transition(AppState.POWER_FAILURE)
            return

        if self.nut.consecutive_failures >= 3:
            print(f"WARNING: NUT unreachable for {self.nut.consecutive_failures} consecutive checks")

        # Periodic full ping sweep
        check_interval = self.monitoring.get('check_interval', 300)
        if now - self._last_ping_sweep >= check_interval:
            self._last_ping_sweep = now
            print(f"\n{'='*60}")
            print(f"[{datetime.now()}] Periodic server check (state: NORMAL)")
            print(f"{'='*60}")
            print(f"UPS Status: {status_str}, Battery: {charge}%\n")

            self._update_all_server_statuses()
            offline = self._get_offline_servers()
            total = len(self._all_servers)

            for group in self.server_groups:
                online_count = sum(1 for s in group['servers']
                                   if self._server_status.get(s['name']) == NodeStatus.ONLINE)
                print(f"Group: {group['name']} (Priority {group['priority']})")
                print(f"  Status: {online_count}/{len(group['servers'])} online")
                for s in group['servers']:
                    st = self._server_status.get(s['name'], NodeStatus.UNREACHABLE)
                    if st != NodeStatus.ONLINE:
                        print(f"    OFFLINE: {s['name']} ({s['ip']})")
                print()

            if offline and power_status == UPSPowerStatus.ONLINE:
                # Crash scenario - servers down but no power event
                auto_wake = self.monitoring.get('auto_wake_on_crash', False)
                if not self._notified_crash:
                    print(f"Crash detected: {len(offline)} server(s) down, UPS is online")
                    self.notifier.notify_crash_detected(offline, auto_wake)
                    self._notified_crash = True

                if auto_wake:
                    print("Auto-wake on crash enabled, starting WOL sequence...")
                    self.notifier.notify_servers_down(offline, total)
                    self._transition(AppState.WAKING)
                    return
            elif not offline:
                self._notified_crash = False
                print("All servers online. No recovery needed.\n")

    def _handle_power_failure(self):
        power_status, charge, status_str = self.nut.get_status()
        fsd_timer = self.monitoring.get('fsd_timer_duration', 120)

        # Update server statuses
        self._update_all_server_statuses()

        shutting_down = self._get_shutting_down_servers()
        if shutting_down and not self._notified_shutdown:
            print(f"Nodes shutting down: {', '.join(shutting_down)}")
            self.notifier.notify_shutdown_in_progress(shutting_down)
            self._notified_shutdown = True

        # Check if any node has gone down or started shutting down
        any_node_down = any(
            s != NodeStatus.ONLINE for s in self._server_status.values()
        )

        # Power restored before FSD?
        if power_status == UPSPowerStatus.ONLINE:
            if not any_node_down:
                print("Power restored, all nodes still up. Entering grace period.")
                self._transition(AppState.GRACE_PERIOD)
                return
            else:
                print("Power restored but nodes already shutting down. Waiting for full shutdown.")
                self._transition(AppState.WAITING_SHUTDOWN)
                return

        # FSD timer expired? Nodes must be shutting down / going off
        if self._time_in_state() > fsd_timer:
            print(f"FSD timer ({fsd_timer}s) expired. Nodes should be shutting down.")
            self._transition(AppState.WAITING_SHUTDOWN)
            return

        # Any node already going down before FSD timer?
        if any_node_down:
            print("Node(s) going down before FSD timer. Transitioning to WAITING_SHUTDOWN.")
            self._transition(AppState.WAITING_SHUTDOWN)
            return

        print(f"Power failure in progress. UPS: {status_str}, Charge: {charge}%, "
              f"Time: {self._time_in_state():.0f}s / {fsd_timer}s FSD timer")

    def _handle_grace_period(self):
        power_status, charge, status_str = self.nut.get_status()
        grace_duration = self.monitoring.get('grace_period_duration', 60)

        # OB again?
        if power_status == UPSPowerStatus.ON_BATTERY:
            print("Power lost again during grace period!")
            self._ob_detected_at = time.time()
            self._transition(AppState.POWER_FAILURE)
            return

        # Check all nodes
        self._update_all_server_statuses()
        any_node_down = any(s != NodeStatus.ONLINE for s in self._server_status.values())

        if any_node_down:
            print("Node went down during grace period. Waiting for full shutdown.")
            self._transition(AppState.WAITING_SHUTDOWN)
            return

        if self._time_in_state() >= grace_duration:
            print(f"Grace period passed ({grace_duration}s), all nodes still up. Returning to normal.")
            self._transition(AppState.NORMAL)
            return

        print(f"Grace period: verifying nodes... ({self._time_in_state():.0f}s / {grace_duration}s)")

    def _handle_waiting_shutdown(self):
        power_status, charge, status_str = self.nut.get_status()
        shutdown_timeout = self.monitoring.get('shutdown_wait_timeout', 600)

        self._update_all_server_statuses()

        # Log status
        for server in self._all_servers:
            name = server['name']
            status = self._server_status.get(name)
            since = self._unreachable_since.get(name)
            unreachable_dur = f" ({time.time() - since:.0f}s)" if since else ""
            print(f"  {name}: {status.name}{unreachable_dur}")

        if not self._notified_all_off and self._all_servers_off():
            print("All servers confirmed off.")
            self.notifier.notify_all_nodes_off()
            self._notified_all_off = True

        # All off and UPS ready?
        if self._all_servers_off():
            is_ready, wake_charge, wake_status = self.nut.is_ready_for_wake()
            if is_ready:
                print(f"All servers off, UPS ready (charge: {wake_charge}%). Preparing to wake.")
                self.notifier.notify_ups_restored(wake_charge)
                self._transition(AppState.READY_TO_WAKE)
                return
            else:
                print(f"All servers off, waiting for UPS. Status: {wake_status}, Charge: {wake_charge}%")

        # Timeout - proceed anyway with stuck node warnings
        if self._time_in_state() > shutdown_timeout:
            still_up = [s['name'] for s in self._all_servers
                        if self._server_status.get(s['name']) == NodeStatus.ONLINE]
            if still_up:
                for name in still_up:
                    print(f"WARNING: Node '{name}' still up after {shutdown_timeout}s timeout")
                    self.notifier.notify_stuck_node(name)

            is_ready, wake_charge, wake_status = self.nut.is_ready_for_wake()
            if is_ready:
                print("Shutdown timeout reached. UPS ready, proceeding with wake-up.")
                self._transition(AppState.READY_TO_WAKE)
                return
            else:
                print(f"Shutdown timeout reached but UPS not ready. "
                      f"Status: {wake_status}, Charge: {wake_charge}%")

        print(f"Waiting for shutdown... ({self._time_in_state():.0f}s / {shutdown_timeout}s timeout)")

    def _handle_ready_to_wake(self):
        startup_delay = self.monitoring.get('startup_delay', 180)
        power_status, charge, status_str = self.nut.get_status()

        # OB again?
        if power_status == UPSPowerStatus.ON_BATTERY:
            print("Power lost again while waiting to wake!")
            self._ob_detected_at = time.time()
            self._transition(AppState.POWER_FAILURE)
            return

        if self._time_in_state() >= startup_delay:
            print(f"Startup delay ({startup_delay}s) passed. Starting wake sequence.")
            self._transition(AppState.WAKING)
            return

        print(f"Waiting for power stability... ({self._time_in_state():.0f}s / {startup_delay}s)")

    def _handle_waking(self):
        """Execute the priority-based WOL sequence"""
        print(f"\n{'='*60}")
        print("Starting server wake sequence by priority")
        print(f"{'='*60}\n")

        # Determine which servers need waking
        self._update_all_server_statuses()
        groups_to_recover = []
        for group in self.server_groups:
            offline_in_group = [s for s in group['servers']
                                if self._server_status.get(s['name']) != NodeStatus.ONLINE]
            if offline_in_group:
                groups_to_recover.append(group['name'])

        if not groups_to_recover:
            print("All servers already online! Nothing to wake.")
            self._transition(AppState.NORMAL)
            return

        self.notifier.notify_recovery_started(groups_to_recover)

        boot_delay_between = self.monitoring.get('boot_delay_between_servers', 15)
        total_woken = 0

        for group in self.server_groups:
            offline_in_group = [s for s in group['servers']
                                if self._server_status.get(s['name']) != NodeStatus.ONLINE]
            if not offline_in_group:
                print(f"Skipping group '{group['name']}' - all online")
                continue

            print(f"\nWaking group: {group['name']} (Priority {group['priority']})")
            print(f"  Servers to wake: {len(offline_in_group)}")

            for i, server in enumerate(offline_in_group):
                self._wake_server(server)
                total_woken += 1
                if i < len(offline_in_group) - 1:
                    print(f"    Waiting {boot_delay_between}s before next server...")
                    time.sleep(boot_delay_between)

            boot_delay_after = group.get('boot_delay_after_group', 0)
            if boot_delay_after > 0:
                print(f"\n  Group complete. Waiting {boot_delay_after}s before next group...")
                time.sleep(boot_delay_after)

        print(f"\n{'='*60}")
        print("Recovery sequence completed!")
        print(f"{'='*60}\n")

        self.notifier.notify_recovery_completed(total_woken)
        self._transition(AppState.NORMAL)

    # -------------------------------------------------------------------------
    # Main tick and run loop
    # -------------------------------------------------------------------------

    def tick(self):
        handler = {
            AppState.NORMAL: self._handle_normal,
            AppState.POWER_FAILURE: self._handle_power_failure,
            AppState.GRACE_PERIOD: self._handle_grace_period,
            AppState.WAITING_SHUTDOWN: self._handle_waiting_shutdown,
            AppState.READY_TO_WAKE: self._handle_ready_to_wake,
            AppState.WAKING: self._handle_waking,
        }[self._state]
        handler()

    def run(self):
        print("=" * 60)
        print("Homelab Recovery Monitor - Shutdown-Aware Mode")
        print("=" * 60)
        print(f"UPS: {self.ups_config['name']}@{self.ups_config['host']}:{self.ups_config['port']}")
        print(f"Minimum battery charge: {self.ups_config['min_charge']}%")
        print(f"NUT poll interval: {self.monitoring.get('nut_poll_interval', 30)}s")
        print(f"Full check interval: {self.monitoring['check_interval']}s")
        print(f"FSD timer: {self.monitoring.get('fsd_timer_duration', 120)}s")
        print(f"Talos monitoring: {'enabled' if self.talos.is_available else 'disabled'}")
        print(f"Auto-wake on crash: {self.monitoring.get('auto_wake_on_crash', False)}")
        print(f"Pushover: {'enabled' if self.notifier.enabled else 'disabled'}")
        print(f"\nConfigured groups ({len(self.server_groups)}):")
        for group in self.server_groups:
            print(f"  Priority {group['priority']}: {group['name']} ({len(group['servers'])} servers)")
        print("\nMonitoring started...\n")

        while True:
            try:
                self.tick()
            except Exception as e:
                error_msg = f"ERROR in main loop: {e}"
                print(error_msg)
                traceback.print_exc()
                self.notifier.notify_error(str(e))

            time.sleep(self.get_poll_interval())


if __name__ == "__main__":
    monitor = PowerNapOver('/app/config/config.yaml')
    monitor.run()
