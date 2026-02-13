#!/usr/bin/env python3
import subprocess
import time
import socket
import yaml
import requests
import os
from datetime import datetime
from typing import List, Dict, Optional

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
        """Send a Pushover notification"""
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
                print(f"✓ Pushover notification sent: {title}")
                return True
            else:
                print(f"✗ Pushover notification failed: {response.status_code} - {response.text}")
                return False

        except Exception as e:
            print(f"✗ Error sending Pushover notification: {e}")
            return False

    def notify_servers_down(self, offline_servers: List[Dict], total_servers: int):
        """Notify when servers are found offline"""
        if not self.notify_on.get('servers_down', True):
            return

        server_list = "\n".join([f"- {s['name']} ({s['ip']})" for s in offline_servers])

        title = f"⚠️ Homelab: {len(offline_servers)}/{total_servers} Servers Down"
        message = f"The following servers are offline:\n\n{server_list}"

        self.send(title, message, priority=1, sound="falling")

    def notify_ups_not_ready(self, status: str, charge: float):
        """Notify when UPS is not ready for recovery"""
        if not self.notify_on.get('ups_not_ready', True):
            return

        title = "⚡ UPS Not Ready"
        message = f"Cannot start recovery.\n\nUPS Status: {status}\nBattery: {charge}%"

        self.send(title, message, priority=1, sound="alien")

    def notify_ups_restored(self, charge: float):
        """Notify when UPS is back online"""
        if not self.notify_on.get('ups_restored', True):
            return

        title = "✅ UPS Restored"
        message = f"UPS is back online.\n\nBattery: {charge}%\nStarting recovery sequence..."

        self.send(title, message, priority=0, sound="magic")

    def notify_recovery_started(self, groups_to_recover: List[str]):
        """Notify when recovery sequence starts"""
        if not self.notify_on.get('recovery_started', True):
            return

        groups = "\n".join([f"- {g}" for g in groups_to_recover])

        title = "🔄 Recovery Started"
        message = f"Starting server recovery sequence.\n\nGroups:\n{groups}"

        self.send(title, message, priority=0)

    def notify_recovery_completed(self, woken_servers: int):
        """Notify when recovery is completed"""
        if not self.notify_on.get('recovery_completed', True):
            return

        title = "✅ Recovery Completed"
        message = f"Server recovery sequence completed.\n\n{woken_servers} server(s) sent WOL packets."

        self.send(title, message, priority=0, sound="magic")

    def notify_error(self, error_msg: str):
        """Notify on errors"""
        if not self.notify_on.get('errors', True):
            return

        title = "❌ Homelab Monitor Error"
        message = f"An error occurred:\n\n{error_msg}"

        self.send(title, message, priority=1, sound="siren")


class PowerNapOver:
    def __init__(self, config_path: str = '/app/config/config.yaml'):
        """Initialize monitor with configuration from YAML file"""
        with open(config_path, 'r') as f:
            self.config = yaml.safe_load(f)

        self.server_groups = self.config['server_groups']
        # Normalize server_groups: ensure 'servers' is always a list
        for group in self.server_groups:
            if group.get('servers') is None:
                group['servers'] = []
        self.ups_config = self.config['ups']
        self.monitoring_config = self.config['monitoring']
        self.network_config = self.config.get('network', {})

        # Initialize Pushover notifier
        pushover_config = self.config.get('pushover', {})

        if os.getenv('PUSHOVER_TOKEN'):
            pushover_config['api_token'] = os.getenv('PUSHOVER_TOKEN')
        if os.getenv('PUSHOVER_USER'):
            pushover_config['user_key'] = os.getenv('PUSHOVER_USER')

        self.notifier = PushoverNotifier(pushover_config)

        # Sort groups by priority
        self.server_groups.sort(key=lambda x: x['priority'])

    def is_host_up(self, ip: str, timeout: Optional[int] = None) -> bool:
        """Check if host responds to ping"""
        if timeout is None:
            timeout = self.monitoring_config.get('ping_timeout', 2)

        try:
            result = subprocess.run(
                ['ping', '-c', '1', '-W', str(timeout), ip],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            return result.returncode == 0
        except Exception as e:
            print(f"Error checking {ip}: {e}")
            return False

    def get_ups_status(self) -> Optional[Dict]:
        """Query UPS status from NUT server"""
        try:
            ups_query = f"{self.ups_config['name']}@{self.ups_config['host']}"
            if self.ups_config.get('port') != 3493:
                ups_query += f":{self.ups_config['port']}"

            result = subprocess.run(
                ['upsc', ups_query],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode != 0:
                print(f"Error querying UPS: {result.stderr}")
                return None

            status = {}
            for line in result.stdout.split('\n'):
                if ':' in line:
                    key, value = line.split(':', 1)
                    status[key.strip()] = value.strip()

            return status
        except Exception as e:
            print(f"Exception querying UPS: {e}")
            return None

    def is_ups_online_and_ready(self) -> tuple[bool, Optional[str], Optional[float]]:
        """Check if UPS is on line power and has sufficient charge
        Returns: (is_ready, status_string, battery_charge)
        """
        ups_status = self.get_ups_status()

        if not ups_status:
            print("WARNING: Cannot get UPS status, assuming not ready")
            return False, "UNKNOWN", 0.0

        status = ups_status.get('ups.status', 'UNKNOWN')
        battery_charge = ups_status.get('battery.charge', '0')

        try:
            charge = float(battery_charge)
        except ValueError:
            charge = 0.0

        print(f"UPS Status: {status}, Battery Charge: {charge}%")

        is_online = 'OL' in status and 'OB' not in status
        has_charge = charge >= self.ups_config['min_charge']

        if not is_online:
            print("UPS is NOT on line power")
            return False, status, charge

        if not has_charge:
            print(f"UPS battery charge too low: {charge}% < {self.ups_config['min_charge']}%")
            return False, status, charge

        print("UPS is online and ready")
        return True, status, charge

    def send_wol(self, mac_address: str):
        """Send Wake-on-LAN magic packet"""
        mac = mac_address.replace(':', '').replace('-', '')
        magic_packet = bytes.fromhex('FF' * 6 + mac * 16)

        broadcast_ip = self.network_config.get('broadcast_ip', '255.255.255.255')
        port = self.network_config.get('wol_port', 9)

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(magic_packet, (broadcast_ip, port))
        sock.close()

    def check_group_status(self, group: Dict) -> Dict:
        """Check status of all servers in a group"""
        result = {
            "group_name": group["name"],
            "priority": group["priority"],
            "total_servers": len(group["servers"]),
            "online_servers": 0,
            "offline_servers": [],
            "all_online": True
        }

        for server in group["servers"]:
            if self.is_host_up(server["ip"]):
                result["online_servers"] += 1
            else:
                result["offline_servers"].append(server)
                result["all_online"] = False

        return result

    def wait_for_ups_ready(self) -> bool:
        """Wait for UPS to be ready, returns True if ready"""
        max_wait = self.monitoring_config.get('max_ups_wait', 3600)
        check_interval = self.monitoring_config.get('ups_check_interval', 60)
        startup_delay = self.monitoring_config.get('startup_delay', 180)

        wait_time = 0
        notified_not_ready = False

        while wait_time < max_wait:
            is_ready, status, charge = self.is_ups_online_and_ready()

            if is_ready:
                # Notify that UPS is restored
                self.notifier.notify_ups_restored(charge)
                print(f"UPS is ready! Waiting additional {startup_delay}s for stability...")
                time.sleep(startup_delay)
                return True
            else:
                # Notify once that UPS is not ready
                if not notified_not_ready:
                    self.notifier.notify_ups_not_ready(status, charge)
                    notified_not_ready = True

                print(f"UPS not ready, waiting {check_interval}s... (total wait: {wait_time}s)")
                time.sleep(check_interval)
                wait_time += check_interval

        print(f"ERROR: UPS not ready after {max_wait}s. Aborting.")
        return False

    def wake_server(self, server: Dict):
        """Send WOL packets to a server with retries"""
        retry_count = self.monitoring_config.get('wol_retry_count', 3)
        retry_delay = self.monitoring_config.get('wol_retry_delay', 1)

        print(f"  └─ Waking {server['name']} ({server['mac']})")

        for i in range(retry_count):
            self.send_wol(server['mac'])
            if i < retry_count - 1:
                time.sleep(retry_delay)

        print(f"     WOL packets sent ({retry_count}x)")

    def recovery_sequence(self):
        """Main recovery sequence - check and wake servers by priority"""
        print(f"\n{'='*60}")
        print(f"[{datetime.now()}] Starting recovery check")
        print(f"{'='*60}\n")

        # Step 1: Check status of all groups
        groups_status = []
        any_server_down = False
        all_offline_servers = []
        total_servers = 0

        for group in self.server_groups:
            status = self.check_group_status(group)
            groups_status.append(status)
            total_servers += status['total_servers']

            print(f"Group: {status['group_name']} (Priority {group['priority']})")
            print(f"  Status: {status['online_servers']}/{status['total_servers']} online")

            if not status['all_online']:
                any_server_down = True
                all_offline_servers.extend(status['offline_servers'])
                for server in status['offline_servers']:
                    print(f"  └─ OFFLINE: {server['name']} ({server['ip']})")
            else:
                print(f"  └─ All servers online ✓")
            print()

        # If all servers are online, nothing to do
        if not any_server_down:
            print("All servers are online. No recovery needed.\n")
            return

        # Notify about offline servers
        self.notifier.notify_servers_down(all_offline_servers, total_servers)

        # Step 2: Check UPS status
        print("Some servers are offline. Checking UPS status...")

        is_ready, status, charge = self.is_ups_online_and_ready()
        if not is_ready:
            print("UPS is not ready. Waiting for UPS restoration...")
            if not self.wait_for_ups_ready():
                print("Aborting recovery - UPS not ready\n")
                return

        # Step 3: Wake servers by priority group
        print("\n" + "="*60)
        print("Starting server wake sequence by priority")
        print("="*60 + "\n")

        # Prepare list of groups that need recovery
        groups_to_recover = [gs['group_name'] for gs in groups_status if not gs['all_online']]
        self.notifier.notify_recovery_started(groups_to_recover)

        boot_delay_between_servers = self.monitoring_config.get('boot_delay_between_servers', 15)
        total_woken = 0

        for group_status in groups_status:
            if group_status['all_online']:
                print(f"Skipping group '{group_status['group_name']}' - all online")
                continue

            # Find the group configuration
            group_config = next(g for g in self.server_groups if g['name'] == group_status['group_name'])

            print(f"\nWaking group: {group_status['group_name']} (Priority {group_config['priority']})")
            print(f"Servers to wake: {len(group_status['offline_servers'])}")

            for i, server in enumerate(group_status['offline_servers']):
                self.wake_server(server)
                total_woken += 1

                # Delay between servers in same group (except last one)
                if i < len(group_status['offline_servers']) - 1:
                    print(f"     Waiting {boot_delay_between_servers}s before next server...")
                    time.sleep(boot_delay_between_servers)

            # Delay after group before starting next priority group
            boot_delay_after_group = group_config.get('boot_delay_after_group', 0)
            if boot_delay_after_group > 0:
                print(f"\n  Group complete. Waiting {boot_delay_after_group}s before next priority group...")
                time.sleep(boot_delay_after_group)

        print("\n" + "="*60)
        print("Recovery sequence completed!")
        print("="*60 + "\n")

        # Notify recovery completed
        self.notifier.notify_recovery_completed(total_woken)

    def run(self):
        """Main monitoring loop"""
        print("="*60)
        print("Homelab Recovery Monitor with UPS Integration")
        print("="*60)
        print(f"UPS: {self.ups_config['name']}@{self.ups_config['host']}:{self.ups_config['port']}")
        print(f"Minimum battery charge: {self.ups_config['min_charge']}%")
        print(f"Check interval: {self.monitoring_config['check_interval']}s")
        print(f"Pushover notifications: {'✓ Enabled' if self.notifier.enabled else '✗ Disabled'}")
        print(f"\nConfigured groups ({len(self.server_groups)}):")

        for group in self.server_groups:
            print(f"  Priority {group['priority']}: {group['name']} ({len(group['servers'])} servers)")

        print("\nMonitoring started...\n")

        while True:
            try:
                self.recovery_sequence()
            except Exception as e:
                error_msg = f"ERROR in main loop: {e}"
                print(error_msg)
                import traceback
                traceback.print_exc()

                # Notify about error
                self.notifier.notify_error(str(e))

            time.sleep(self.monitoring_config['check_interval'])

if __name__ == "__main__":
    monitor = PowerNapOver('/app/config/config.yaml')
    monitor.run()
