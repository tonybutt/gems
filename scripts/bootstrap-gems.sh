#!/usr/bin/env bash
set -euo pipefail

TALOS_DIR=talos
CLUSTER_DIR=clusters/gems

# Generate Talos config for Gem Master Control Plane Node
echo "Generating Talos config for Gem Master Control Plane Node"
sops -d -i "$TALOS_DIR/secrets.yaml"
talosctl gen config gems https://192.168.86.250:6443 \
    --with-secrets "$TALOS_DIR/secrets.yaml" \
    --config-patch "@$TALOS_DIR/nodes/gem-master-0.yaml,@$TALOS_DIR/patches/base.yaml" \
    -o "$TALOS_DIR" \
    --force
sops -e -i "$TALOS_DIR/secrets.yaml"

# Apply Talos config
echo "Applying generated Talos config"
set +e
if ! talosctl apply-config -n 192.168.86.250 --file "$TALOS_DIR/controlplane.yaml" --insecure; then
    echo "First attempt failed, trying with talosconfig..."
    talosctl apply-config -n 192.168.86.250 --file "$TALOS_DIR/controlplane.yaml" --talosconfig="$TALOS_DIR/talosconfig"
fi

# Send bootstrap command
echo "Sending bootstrap command"
talosctl bootstrap -n 192.168.86.250 -e 192.168.86.250 --talosconfig="$TALOS_DIR/talosconfig"
set -e

# Apply Cilium
echo "Applying Cilium"
kustomize build infrastructure/controllers/cilium | kubectl apply -f -

# Apply Flux
echo "Applying Flux"
secret_file="$CLUSTER_DIR/flux-system/age.agekey"

set +e
sops -d -i "$secret_file"
kubectl create secret generic sops-age --namespace=flux-system --from-file=age.agekey="$secret_file" || true
kustomize build "$CLUSTER_DIR/flux-system" | kubectl apply -f -
sops -e -i "$secret_file"
set -e

echo "Bootstrap complete"
