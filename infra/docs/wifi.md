# WiFi SSIDs

| SSID | VLAN | Band | Hidden | App | Isolation | Security |
|------|------|------|--------|-----|-----------|----------|
| This Is Fine | 1 | 2.4 + 5 GHz | yes | Standard | no | WPA2/WPA3 |
| Death Star Core | 10 | 2.4 + 5 GHz | yes | Standard | no | WPA2/WPA3 |
| The Grid | 20 | 2.4 + 5 GHz | no | Standard | no | WPA2/WPA3 |
| R2D2 Net | 30 | 2.4 GHz | no | IoT | no | WPA2 |
| The Void | 40 | 2.4 GHz | yes | IoT | no | WPA2 |
| Area 51 | 50 | 2.4 + 5 GHz | no | Standard | yes | WPA2/WPA3 |
| LAN Solo | 60 | 2.4 + 5 GHz | no | Standard | yes | WPA2/WPA3 |

IoT SSIDs use WPA2 + 2.4 GHz only (ESP/smart devices compatibility).
DHCP Guarding enabled on all UniFi networks, pointing to glados gateway IP.
Gateway mDNS Proxy: Off (glados handles routing).
