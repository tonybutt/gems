# Treefmt configuration
{ pkgs, treefmt-nix }:

treefmt-nix.lib.evalModule pkgs {
  projectRootFile = "flake.nix";

  settings.global.excludes = [
    # Rendered helm manifests
    "**/manifests/*.yaml"
    "**/cilium.yaml"
    "**/gotk-components.yaml"
    # SOPS encrypted files
    "**/secrets.yaml"
    "**/*.encrypted.*"
    # Credentials
    "**/credentials.json"
  ];

  programs = {
    nixfmt.enable = true;
    prettier = {
      enable = true;
      includes = [
        "*.md"
        "*.json"
        "*.yaml"
        "*.yml"
      ];
      excludes = [ "**/credentials.json" ];
    };
  };
}
