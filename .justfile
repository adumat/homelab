#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "kubernetes/bootstrap"
mod kube "kubernetes"
mod talos "kubernetes/talos"

[private]
default:
    just -l

[doc('Fetch the SOPS age key from Bitwarden into ./age.key')]
setup:
    #!/usr/bin/env bash
    # Everything sops-encrypted in this repo needs this key, including the
    # cluster's own Bitwarden access token - so a fresh clone cannot decrypt
    # anything without it. Requires BWS_ACCESS_TOKEN (see .env); if the laptop is
    # gone, mint a new access token from the Bitwarden web vault first.
    if [[ -f age.key ]]; then
        just log info "age.key already present" pubkey "$(age-keygen -y age.key)"
        exit 0
    fi
    bws secret get c26e9d84-2735-4317-9564-b3df011ffd26 -o json | jq -r '.value' > age.key
    chmod 600 age.key
    # Printing the PUBLIC key is safe, and it is the quickest way to confirm the
    # fetch produced the key .sops.yaml actually expects.
    just log info "Wrote age.key" pubkey "$(age-keygen -y age.key)"

[doc('Check node health: ping, Talos API, Kubernetes status')]
check-nodes:
    "{{ justfile_dir() }}/scripts/check-nodes.sh"

[doc('Audit backup coverage against backup-policy.yaml')]
backup-audit:
    "{{ justfile_dir() }}/scripts/backup-audit.sh"

[doc('Mount an NFS share from elizabeth.lan to ./mnt/<name> (sudo)')]
mount name:
    sudo "{{ justfile_dir() }}/scripts/mount-nfs.sh" mount "{{ name }}"

[doc('Unmount an NFS share at ./mnt/<name> (sudo)')]
unmount name:
    sudo "{{ justfile_dir() }}/scripts/mount-nfs.sh" unmount "{{ name }}"

[doc('Force-unmount all NFS shares under ./mnt/ (sudo)')]
unmount-all:
    sudo "{{ justfile_dir() }}/scripts/mount-nfs.sh" unmount-all

[doc('List available NFS shares and their mount status')]
mounts:
    "{{ justfile_dir() }}/scripts/mount-nfs.sh" list

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    minijinja-cli "{{ file }}" {{ args }} | "{{ justfile_dir() }}/scripts/bws-inject"
