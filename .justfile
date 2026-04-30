#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "kubernetes/bootstrap"
mod kube "kubernetes"
mod talos "kubernetes/talos"

[private]
default:
    just -l

[doc('Check node health: ping, Talos API, Kubernetes status')]
check-nodes:
    "{{ justfile_dir() }}/scripts/check-nodes.sh"

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
