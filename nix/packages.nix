# Custom packages/scripts
{ pkgs }:

let
  nodes = import ./nodes.nix;

  # Format nodes as "name:ip:type" for shell
  talosNodes = builtins.filter (n: n.os == "talos") nodes.nodes;

  nodesArray = builtins.concatStringsSep " " (map (n: ''"${n.name}:${n.ip}:${n.type}"'') talosNodes);

  firstControlPlane = (builtins.head (builtins.filter (n: n.type == "controlplane") nodes.nodes)).ip;

  bootstrapScript = ''
    FIRST_MASTER_IP="${firstControlPlane}"
  ''
  + builtins.readFile ../scripts/bootstrap-gems.sh;

  talosGenScript = ''
    # Injected from nix/nodes.nix
    CLUSTER_NAME="${nodes.cluster.name}"
    CLUSTER_ENDPOINT="${nodes.cluster.endpoint}"
    TALOS_VERSION="${nodes.versions.talos}"
    TALOS_SCHEMATIC="${nodes.schematic}"
    KUBERNETES_VERSION="${nodes.versions.kubernetes}"
    NODES=(${nodesArray})

  ''
  + builtins.readFile ../scripts/talos-gen.sh;

in
{
  render-helm = pkgs.writeShellApplication {
    name = "render-helm";
    runtimeInputs = with pkgs; [
      kubernetes-helm
      yq-go
      findutils
      gnused
      coreutils
      git
    ];
    text = builtins.readFile ../scripts/render-helm.sh;
  };

  sops-reencrypt = pkgs.writeShellApplication {
    name = "sops-reencrypt";
    runtimeInputs = with pkgs; [
      git
      findutils
      gnugrep
      sops
    ];
    text = builtins.readFile ../scripts/sops-reencrypt.sh;
  };

  menu = pkgs.writeShellApplication {
    name = "menu";
    runtimeInputs = with pkgs; [ ];
    text = builtins.readFile ../scripts/menu.sh;
  };

  bootstrap-gems = pkgs.writeShellApplication {
    name = "bootstrap-gems";
    runtimeInputs = with pkgs; [
      talosctl
      kubectl
      kustomize
      sops
    ];
    text = bootstrapScript;
  };

  talos-gen = pkgs.writeShellApplication {
    name = "talos-gen";
    runtimeInputs = with pkgs; [
      talosctl
      sops
      gnused
      coreutils
      git
      yq-go
      jq
      age
      nix
      openssl
    ];
    text = talosGenScript;
  };

  validate-kustomize = pkgs.writeShellApplication {
    name = "validate-kustomize";
    runtimeInputs = with pkgs; [
      kustomize
      git
      findutils
      coreutils
    ];
    text = builtins.readFile ../scripts/validate-kustomize.sh;
  };

  talos-iso = pkgs.writeShellApplication {
    name = "talos-iso";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      git
    ];
    text = ''
      # Injected from nix/nodes.nix
      TALOS_VERSION="${nodes.versions.talos}"
    ''
    + builtins.readFile ../scripts/talos-iso.sh;
  };
}
