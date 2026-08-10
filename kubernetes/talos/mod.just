set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

scripts_dir := justfile_dir() + '/scripts'
talos_dir := justfile_dir() + '/kubernetes/talos'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`
nodes := `talosctl config info -o yaml | yq -e '.nodes | join (" ")'`

[private]
default:
    just -l talos

[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config "{{ node }}" | talosctl -n "{{ node }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos machine image')]
download-image version schematic:
    #!/usr/bin/env bash
    set -euo pipefail
    # Same secureboot derivation as upgrade-node: this cluster runs it off, and the
    # secureboot ISO will not boot these nodes.
    # No -e on yq: it exits 1 when the value is false, which under set -e would
    # kill the recipe instead of selecting the non-secureboot path.
    if [[ "$(yq '.nodes[0].machineSpec.secureboot' "{{ talos_dir }}/talconfig.yaml")" == "true" ]]; then
        suffix="-secureboot"
    else
        suffix=""
    fi
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/images/talos-v{{ version }}${suffix}-{{ replace_regex(schematic, '^(.{8}).*', '$1') }}.iso" \
        "https://factory.talos.dev/image/{{ schematic }}/{{ version }}/metal-amd64${suffix}.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Generate schematic ID from Talos schematic')]
gen-schematic-id:
    yq -e '.nodes[0].schematic' "{{ talos_dir }}/talconfig.yaml" | curl -sX POST --data-binary @- "https://factory.talos.dev/schematics" | jq -r '.id'

[doc('Generate Talos config')]
gen-config:
    just template "{{ talos_dir }}/talsecret.yaml.j2" > "{{ talos_dir }}/talsecret.yaml"
    just template "{{ talos_dir }}/talenv.secrets.yaml.j2" > "{{ talos_dir }}/talenv.secrets.yaml"
    talhelper genconfig -e "{{ talos_dir }}/talenv.yaml" -e "{{ talos_dir }}/talenv.secrets.yaml"

[doc('Render Talos config for a node')]
render-config node:
    bat "{{ talos_dir }}/clusterconfig/kubernetes-$(yq -e '.nodes[] | select(.ipAddress == "{{ node }}") | .hostname' "{{ talos_dir }}/talconfig.yaml").yaml"

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" --default="No" && \
        talosctl -n {{ node }} reboot -m powercycle || exit 0

[doc('Reset all nodes')]
reset-all-nodes:
    gum confirm "Reset ALL nodes?" --default="No" && \
    for n in {{ nodes }}; do \
        if op=$(talosctl -n "$n" reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --wait=false --reboot 2>&1); then \
            just log info "Node reset successfully" "node" "$n"; \
        elif [[ "$op" == *"certificate required"* ]]; then \
            just log info "Node already reset" "node" "$n"; \
        else \
            just log error "Failed to reset node" "node" "$n" "output" "$op"; \
        fi; \
    done

[doc('Reset a node')]
reset-node node:
    gum confirm "Reset node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" reset --system-labels-to-wipe EPHEMERAL,STATE --graceful=false --reboot || exit 0

[doc('Shutdown a node')]
shutdown-node node:
    gum confirm "Shutdown node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" shutdown --force || exit 0

[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "{{ controller }}" upgrade-k8s --to {{ version }}

[doc('Check TSO status on all e1000e nodes')]
check-tso:
    "{{ talos_dir }}/check-tso.sh"

[doc('Upgrade Talos version on a node')]
upgrade-node node version *args:
    #!/usr/bin/env bash
    set -euo pipefail
    # The installer image path depends on secureboot, and this cluster runs with it
    # off. Derived from talconfig.yaml rather than hardcoded, so flipping
    # machineSpec.secureboot is enough and cannot silently disagree with the image.
    # No -e on yq: it exits 1 when the value is false, which under set -e would
    # kill the recipe instead of selecting the non-secureboot path.
    if [[ "$(yq '.nodes[0].machineSpec.secureboot' "{{ talos_dir }}/talconfig.yaml")" == "true" ]]; then
        variant="metal-installer-secureboot"
    else
        variant="metal-installer"
    fi
    talosctl -n "{{ node }}" upgrade -i "factory.talos.dev/${variant}/$(just talos gen-schematic-id):v{{ version }}" -m powercycle --timeout=10m {{ args }}
