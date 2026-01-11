#!/usr/bin/env bash
# Download Talos ISO with custom extensions (iSCSI for OpenEBS)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ISO_DIR="$REPO_ROOT/talos/iso"

usage() {
  echo "Usage: talos-iso [OPTIONS]"
  echo ""
  echo "Download Talos ISO with iSCSI extensions for OpenEBS"
  echo ""
  echo "Options:"
  echo "  -v, --version <ver>  Talos version (default: from nix/nodes.nix)"
  echo "  -o, --output <dir>   Output directory (default: talos/iso)"
  echo "  -h, --help           Show this help"
  echo ""
  echo "Extensions included:"
  echo "  - siderolabs/iscsi-tools (for OpenEBS)"
  echo ""
  echo "Example:"
  echo "  talos-iso                    # Download ISO for current version"
  echo "  talos-iso -v 1.9.3           # Download specific version"
}

OUTPUT_DIR="$ISO_DIR"

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version)
      TALOS_VERSION="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Create schematic for Image Factory
# See: https://factory.talos.dev/
SCHEMATIC=$(cat <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
EOF
)

echo "Creating schematic with iSCSI extensions..."
SCHEMATIC_ID=$(echo "$SCHEMATIC" | curl -s -X POST --data-binary @- https://factory.talos.dev/schematics | jq -r '.id')

if [ -z "$SCHEMATIC_ID" ] || [ "$SCHEMATIC_ID" = "null" ]; then
  echo "Error: Failed to create schematic"
  exit 1
fi

echo "Schematic ID: $SCHEMATIC_ID"

# Construct download URL
ISO_URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/v${TALOS_VERSION}/metal-amd64.iso"
ISO_FILE="$OUTPUT_DIR/talos-${TALOS_VERSION}-iscsi-amd64.iso"

echo ""
echo "Talos version: v${TALOS_VERSION}"
echo "Download URL: $ISO_URL"
echo "Output: $ISO_FILE"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Download ISO
echo "Downloading ISO..."
if curl -L -o "$ISO_FILE" "$ISO_URL" --progress-bar; then
  echo ""
  echo "ISO downloaded successfully: $ISO_FILE"
  echo ""
  echo "To verify, check the ISO size:"
  ls -lh "$ISO_FILE"
else
  echo "Error: Failed to download ISO"
  exit 1
fi

# Add to gitignore if not already there
GITIGNORE="$REPO_ROOT/talos/.gitignore"
if ! grep -q "iso/" "$GITIGNORE" 2>/dev/null; then
  echo "iso/" >> "$GITIGNORE"
  echo "Added iso/ to talos/.gitignore"
fi

echo ""
echo "Next steps:"
echo "  1. Flash ISO to USB: dd if=$ISO_FILE of=/dev/sdX bs=4M status=progress"
echo "  2. Boot target machine from USB"
echo "  3. Run: talos-gen secrets && talos-gen configs"
echo "  4. Apply config: apply-gem-master-0"
