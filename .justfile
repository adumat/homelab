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

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    minijinja-cli "{{ file }}" {{ args }} | "{{ justfile_dir() }}/scripts/bws-inject"
