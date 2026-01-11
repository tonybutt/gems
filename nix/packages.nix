# Custom packages/scripts
{ pkgs }:

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
}
