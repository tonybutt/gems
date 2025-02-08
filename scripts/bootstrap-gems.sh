GEMS_DIR=clusters/gems

# Generate Talos config for Gem Master Control Plane Node
echo "Generating Talos config for Gem Master Control Plane Node"
sops -d -i "$GEMS_DIR/infra/secrets.yaml"
talosctl gen config gems https://192.168.86.250:6443 \
    --with-secrets "$GEMS_DIR/infra/secrets.yaml" \
    --config-patch "@$GEMS_DIR/infra/nodes/gem-master-0.yaml" \
    -o "$GEMS_DIR/infra" \
    --force
sops -e -i "$GEMS_DIR/infra/secrets.yaml"

# Apply Talos config
echo "Applying generated Talos config"
set +e  # Prevent script from exiting on error
if ! talosctl apply-config -n 192.168.86.250 --file "$GEMS_DIR/infra/controlplane.yaml" --insecure; then
    echo "First attempt failed, trying with talosconfig..."
    talosctl apply-config -n 192.168.86.250 --file "$GEMS_DIR/infra/controlplane.yaml" --talosconfig="$GEMS_DIR/infra/talosconfig"
fi

# Send bootstrap command
echo "Sending bootstrap command"
talosctl bootstrap -n 192.168.86.250 -e 192.168.86.250 --talosconfig="$GEMS_DIR/infra/talosconfig"
set -e
# Apply Cilium
echo "Applying Cilium"
kustomize build "$GEMS_DIR/platform" | kubectl apply -f -

# Apply Flux
echo "Applying Flux"
secret_file="$GEMS_DIR/flux-system/age.agekey"

set +e
sops -d -i $secret_file
cat $secret_file | kubectl create secret generic sops-age --namespace=flux-system --from-file=age.agekey=/dev/stdin
kustomize build "$GEMS_DIR/flux-system" | kubectl apply -f -
sops -e -i $secret_file
set -e

echo "Bootstrap complete"
exit 0
