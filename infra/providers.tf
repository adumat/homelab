provider "proxmox" {
  endpoint = var.proxmox_url
  insecure = true

  # Privileged LXC operations require root@pam username/password auth.
  # API tokens can't set feature flags on privileged containers.
  username = var.proxmox_username
  password = var.proxmox_password

  # SSH for privileged operations (e.g., privileged LXC feature flags)
  ssh {
    agent    = true
    username = "root"
  }
}

provider "opnsense" {
  uri            = var.opnsense_url
  api_key        = var.opnsense_api_key
  api_secret     = var.opnsense_api_secret
  allow_insecure = true
  retries        = 10
  min_backoff    = 5
  max_backoff    = 30
}

# Raw OPNsense API access for resources not covered by the opnsense provider
# (FRR/BGP enable, DDNS accounts, TFTP)
# NOTE: No Content-Type header — OPNsense rejects JSON header on GET reads.
# Each resource sets content type via create/update headers if needed.
provider "restapi" {
  uri                   = var.opnsense_url
  write_returns_object  = true
  create_returns_object = true
  insecure              = true

  username = var.opnsense_api_key
  password = var.opnsense_api_secret
}
