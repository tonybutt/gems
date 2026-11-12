# Development shell configuration
{
  pkgs,
  packages,
  nodes,
  git-hooks,
  deploy-rs,
  agenix,
}:

let
  nodeConfig = import ./nodes.nix;
  talosNodes = builtins.filter (n: n.os == "talos") nodeConfig.nodes;
  nixosNodes = builtins.filter (n: n.os == "nixos") nodeConfig.nodes;
  controlPlanes = builtins.filter (n: n.type == "controlplane") nodeConfig.nodes;
  firstControlPlane = (builtins.head controlPlanes).ip;

  # Generate upgrade scripts for each node
  upgradeScripts = map (
    node:
    pkgs.writeShellScriptBin "upgrade-${node.name}" ''
      set -euo pipefail
      VERSION="''${1:-${nodeConfig.versions.talos}}"
      echo "Upgrading ${node.name} (${node.ip}) to Talos v$VERSION..."
      ${pkgs.talosctl}/bin/talosctl upgrade \
        --talosconfig talos/gen/talosconfig \
        --image "factory.talos.dev/metal-installer/${nodeConfig.schematic}:v$VERSION" \
        -n ${node.ip}
    ''
  ) talosNodes;

  # Generate apply-config scripts for each node
  # All patches are baked into generated configs by talos-gen configs
  # Use --insecure flag for first apply (before certs are set)
  applyScripts = map (
    node:
    pkgs.writeShellScriptBin "apply-${node.name}" ''
      set -euo pipefail
      INSECURE=""
      if [ "''${1:-}" = "--insecure" ] || [ "''${1:-}" = "-i" ]; then
        INSECURE="--insecure"
      fi
      ${pkgs.talosctl}/bin/talosctl apply-config \
        --talosconfig talos/gen/talosconfig \
        -n ${node.ip} \
        --file talos/gen/${node.name}.yaml \
        $INSECURE
    ''
  ) talosNodes;

  deployScripts = map (
    node:
    pkgs.writeShellScriptBin "apply-${node.name}" ''
      set -euo pipefail
      echo "Deploying ${node.name} (${node.ip}) with deploy-rs..."
      ${deploy-rs}/bin/deploy ".#${node.name}" "$@"
    ''
  ) nixosNodes;

  # Kubernetes upgrade script
  upgradeK8s = pkgs.writeShellScriptBin "upgrade-k8s" ''
    set -euo pipefail
    VERSION="''${1:-${nodeConfig.versions.kubernetes}}"
    echo "Upgrading Kubernetes to v$VERSION..."
    ${pkgs.talosctl}/bin/talosctl upgrade-k8s \
      --talosconfig talos/gen/talosconfig \
      -n ${firstControlPlane} \
      --to "$VERSION"
  '';

  # Menu script
  showMenu = pkgs.writeShellScriptBin "menu" ''
    echo ""
    echo "  Gems Homelab Cluster (Talos ${nodeConfig.versions.talos} / K8s ${nodeConfig.versions.kubernetes})"
    echo ""
    echo "  Node commands:"
    echo "    upgrade-<node> [version]  Upgrade Talos on node (default: ${nodeConfig.versions.talos})"
    echo "    upgrade-k8s [version]     Upgrade Kubernetes (default: ${nodeConfig.versions.kubernetes})"
    echo "    apply-<node> [--insecure] Apply config to Talos node (-i for first apply)"
    echo "    apply-<nixos node>        Deploy NixOS node with deploy-rs"
    echo ""
    echo "  Nodes: ${builtins.concatStringsSep ", " (map (n: n.name) talosNodes)}"
    echo ""
    echo "  Talos setup:"
    echo "    talos-iso                 Download ISO with iSCSI extensions"
    echo "    talos-gen secrets         Generate new cluster secrets"
    echo "    talos-gen configs         Generate node configs to talos/gen/"
    echo ""
    echo "  Tools:"
    echo "    render-helm [--all]       Render helm charts"
    echo "    sops-reencrypt            Re-encrypt SOPS files"
    echo "    bootstrap-gems            Bootstrap cluster"
    echo "    kubeconfig                Get kubeconfig"
    echo ""
    echo "  Formatting:"
    echo "    nix fmt                   Format all files"
    echo ""
  '';

  kubeconfig = pkgs.writeShellScriptBin "kubeconfig" ''
    ${pkgs.talosctl}/bin/talosctl kubeconfig \
      --talosconfig talos/gen/talosconfig \
      -n ${firstControlPlane} \
      -e ${firstControlPlane} \
      --context ${nodeConfig.cluster.name}
  '';

in
pkgs.mkShell {
  name = "gems-shell";

  packages =
    with pkgs;
    [
      # Kubernetes/Talos tools
      talosctl
      kubectl
      kubernetes-helm
      kustomize
      fluxcd
      nixos-anywhere
      deploy-rs
      agenix
      yq-go

      # Secrets
      sops
      age

      # Cloudflare
      cloudflared

      # Identity
      kanidm_1_11

      # Custom packages
      packages.render-helm
      packages.sops-reencrypt
      packages.bootstrap-gems
      packages.talos-gen
      packages.talos-iso

      # Node scripts
      showMenu
      kubeconfig
      upgradeK8s

      # Github
      gh

      # Image tools (for social preview generation)
      librsvg # rsvg-convert for SVG to PNG
    ]
    ++ upgradeScripts
    ++ applyScripts
    ++ deployScripts;

  env = {
    TALOSCONFIG = "talos/gen/talosconfig";
    KANIDM_URL = "https://sso.abutt.dev";
    KANIDM_VERIFY_CA = "true";
  };

  shellHook = ''
    ${git-hooks.shellHook}
    menu
  '';
}
