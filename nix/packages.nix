# Custom packages/scripts
{ pkgs }:

let
  nodes = import ./nodes.nix;

  # Format nodes as "name:ip:type" for shell
  nodesArray = builtins.concatStringsSep " " (
    map (n: ''"${n.name}:${n.ip}:${n.type}"'') nodes.nodes
  );

  talosGenScript = ''
    # Injected from nix/nodes.nix
    CLUSTER_NAME="${nodes.cluster.name}"
    CLUSTER_ENDPOINT="${nodes.cluster.endpoint}"
    TALOS_VERSION="${nodes.versions.talos}"
    KUBERNETES_VERSION="${nodes.versions.kubernetes}"
    INSTALL_DISK="${nodes.machineConfig.install.disk}"
    NODES=(${nodesArray})

  '' + builtins.readFile ../scripts/talos-gen.sh;

in
{
  render-helm = pkgs.writeShellApplication {
    name = "render-helm";
    runtimeInputs = with pkgs; [ kubernetes-helm yq-go findutils gnused coreutils git ];
    text = builtins.readFile ../scripts/render-helm.sh;
  };

  sops-reencrypt = pkgs.writeShellApplication {
    name = "sops-reencrypt";
    runtimeInputs = with pkgs; [ git findutils gnugrep sops ];
    text = builtins.readFile ../scripts/sops-reencrypt.sh;
  };

  menu = pkgs.writeShellApplication {
    name = "menu";
    runtimeInputs = with pkgs; [ ];
    text = builtins.readFile ../scripts/menu.sh;
  };

  bootstrap-gems = pkgs.writeShellApplication {
    name = "bootstrap-gems";
    runtimeInputs = with pkgs; [ talosctl kubectl kustomize sops ];
    text = builtins.readFile ../scripts/bootstrap-gems.sh;
  };

  talos-gen = pkgs.writeShellApplication {
    name = "talos-gen";
    runtimeInputs = with pkgs; [ talosctl sops gnused coreutils git ];
    text = talosGenScript;
  };
}
