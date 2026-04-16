# ── Proxmox ──────────────────────────────────────────────
variable "proxmox_url" {
  description = "Proxmox API endpoint"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token (user@realm!tokenid=secret)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_username" {
  description = "Proxmox username (e.g., root@pam)"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "matryoshka"
}

# ── OPNsense ─────────────────────────────────────────────
variable "opnsense_url" {
  description = "OPNsense API endpoint"
  type        = string
}

variable "opnsense_api_key" {
  description = "OPNsense API key"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "OPNsense API secret"
  type        = string
  sensitive   = true
}

# ── WireGuard ────────────────────────────────────────────
variable "wg_private_key" {
  description = "WireGuard server private key"
  type        = string
  sensitive   = true
}

variable "wg_public_key" {
  description = "WireGuard server public key"
  type        = string
}

variable "wg_peer_public_keys" {
  description = "Map of peer name to public key"
  type        = map(string)
  sensitive   = true
}

# ── Cloudflare ───────────────────────────────────────────
variable "cloudflare_api_token" {
  description = "Cloudflare API token for DDNS"
  type        = string
  sensitive   = true
}

variable "base_domain" {
  description = "Base domain (secret — repo is public)"
  type        = string
  sensitive   = true
}
