{
  description = "Gems homelab cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, treefmt-nix, git-hooks }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Import custom packages
      packages = import ./nix/packages.nix { inherit pkgs; };

      # Import node definitions
      nodes = import ./nix/nodes.nix;

      # Treefmt configuration
      treefmtEval = treefmt-nix.lib.evalModule pkgs {
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
          nixpkgs-fmt.enable = true;
          yamlfmt = {
            enable = true;
            excludes = [ "*.json" ];
          };
          prettier = {
            enable = true;
            includes = [ "*.md" "*.json" ];
            excludes = [ "**/credentials.json" ];
          };
        };
      };

      # Git hooks configuration
      gitHooksModule = git-hooks.lib.${system}.run {
        src = ./.;
        hooks = {
          treefmt = {
            enable = true;
            package = treefmtEval.config.build.wrapper;
            entry = "${treefmtEval.config.build.wrapper}/bin/treefmt --fail-on-change";
          };
          render-helm = {
            enable = true;
            name = "render-helm";
            entry = "${packages.render-helm}/bin/render-helm";
            files = "helm-values\\.yaml$";
            pass_filenames = true;
          };
          commitizen.enable = true;
        };
      };

    in
    {
      # Formatter for `nix fmt`
      formatter.${system} = treefmtEval.config.build.wrapper;

      # Packages for `nix run .#<name>`
      packages.${system} = {
        inherit (packages) render-helm sops-reencrypt bootstrap-gems menu;
        default = packages.render-helm;
      };

      # Dev shell for `nix develop`
      devShells.${system}.default = import ./nix/shell.nix {
        inherit pkgs packages nodes;
        git-hooks = gitHooksModule;
      };

      # For CI checks
      checks.${system} = {
        formatting = treefmtEval.config.build.check self;
        pre-commit = gitHooksModule;
      };
    };
}
