# Development shell configuration
{ pkgs, packages, nodes, git-hooks }:

let
  nodeConfig = import ./nodes.nix;

  # Generate upgrade scripts for each node
  upgradeScripts = map
    (node: pkgs.writeShellScriptBin "upgrade-${node.name}" ''
      set -euo pipefail
      if [ -z "''${1:-}" ]; then
        echo "Usage: upgrade-${node.name} <version>"
        echo "Example: upgrade-${node.name} 1.9.3"
        exit 1
      fi
      ${pkgs.talosctl}/bin/talosctl upgrade --image "ghcr.io/siderolabs/installer:v$1" -n ${node.ip}
    '')
    nodeConfig.nodes;

  # Generate apply-config scripts for each node
  applyScripts = map
    (node: pkgs.writeShellScriptBin "apply-${node.name}" ''
      set -euo pipefail
      ${pkgs.talosctl}/bin/talosctl apply-config \
        -n ${node.ip} \
        --file talos/${node.type}.yaml \
        -p @talos/nodes/${node.name}.yaml \
        -p @talos/patches/base.yaml
    '')
    nodeConfig.nodes;

  # Menu script
  showMenu = pkgs.writeShellScriptBin "menu" ''
    echo ""
    echo "  Gems Homelab Cluster"
    echo ""
    echo "  Node commands:"
    echo "    upgrade-<node> <version>  Upgrade Talos on node"
    echo "    apply-<node>              Apply config to node"
    echo ""
    echo "  Nodes: ${builtins.concatStringsSep ", " (map (n: n.name) nodeConfig.nodes)}"
    echo ""
    echo "  Tools:"
    echo "    render-helm [--all] [files...]  Render helm charts"
    echo "    sops-reencrypt [dir]            Re-encrypt SOPS files"
    echo "    bootstrap-gems                  Bootstrap cluster"
    echo "    kubeconfig                      Get kubeconfig"
    echo ""
    echo "  Formatting:"
    echo "    nix fmt                         Format all files"
    echo ""
  '';

  kubeconfig = pkgs.writeShellScriptBin "kubeconfig" ''
    ${pkgs.talosctl}/bin/talosctl kubeconfig \
      -n ${nodeConfig.cluster.endpoint} \
      -e ${nodeConfig.cluster.endpoint} \
      --context ${nodeConfig.cluster.name} \
      --talosconfig=./talos/talosconfig
  '';

in
pkgs.mkShell {
  name = "gems-shell";

  packages = with pkgs; [
    # Kubernetes/Talos tools
    talosctl
    kubectl
    kubernetes-helm
    kustomize
    fluxcd

    # Secrets
    sops
    age

    # Cloudflare
    cloudflared

    # Custom packages
    packages.render-helm
    packages.sops-reencrypt
    packages.bootstrap-gems

    # Node scripts
    showMenu
    kubeconfig
  ] ++ upgradeScripts ++ applyScripts;

  env = {
    TALOSCONFIG = "talos/talosconfig";
  };

  shellHook = ''
    ${git-hooks.shellHook}
    menu
  '';
}
