# Treefmt configuration
{ pkgs, treefmt-nix }:

let
  kubernetesManifests = [
    "apps/**/*.yaml"
    "clusters/**/*.yaml"
    "infrastructure/**/*.yaml"
  ];
  nonKubernetesYaml = [
    "**/helm-values.yaml"
    "apps/cloudflared/*/config.yaml"
  ];
in
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
    gofumpt.enable = true;
    prettier = {
      enable = true;
      includes = [
        "*.md"
        "*.json"
        ".sops.yaml"
        "talos/**/*.yaml"
      ]
      ++ nonKubernetesYaml;
      excludes = [ "**/credentials.json" ];
    };
    yamlfmt = {
      enable = true;
      includes = kubernetesManifests;
      excludes = nonKubernetesYaml;
      settings.formatter.type = "kyaml";
    };
  };
}
