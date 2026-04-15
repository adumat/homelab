# Non-secret values — safe to commit (secrets come from BWS via TF_VAR_*)

# Test VM (QEMU local)
proxmox_url  = "https://localhost:8006"
proxmox_node = "pve"

opnsense_url = "https://127.0.0.1:4443"

# Production values (uncomment for real deployment):
# proxmox_url  = "https://10.1.1.1:8006"
# opnsense_url = "https://10.1.1.1"
