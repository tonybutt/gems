VALUES_FILE="./clusters/gems/kustomize/platform/cilium/helm-values.yaml"
OUTPUT_FILE="./clusters/gems/kustomize/platform/cilium/cilium.yaml"
TEMP_FILE=$(mktemp)

helm template cilium cilium/cilium --namespace kube-system --version 1.16.3 -f "$VALUES_FILE" > "$TEMP_FILE"

if cmp -s "$TEMP_FILE" "$OUTPUT_FILE"; then
    echo "No changes in Kubernetes manifests."
else
    echo "Updating Kubernetes manifests."
    mv "$TEMP_FILE" "$OUTPUT_FILE"
fi

[ -f "$TEMP_FILE" ] && rm "$TEMP_FILE"

exit 0
