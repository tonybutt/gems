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

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.darwin.follows = "";
      inputs.home-manager.follows = "";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix-shell = {
      url = "github:aciceri/agenix-shell";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
      inputs.git-hooks-nix.follows = "git-hooks";
      inputs.nix-github-actions.follows = "";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      git-hooks,
      disko,
      agenix,
      agenix-shell,
      deploy-rs,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      packages = import ./nix/packages.nix { inherit pkgs; };
      nodes = import ./nix/nodes.nix;
      gpuNode = nixpkgs.lib.findFirst (n: n.name == "gem-gpu-0") {
        name = "gem-gpu-0";
        ip = "0.0.0.0";
        type = "worker";
        os = "nixos";
      } nodes.nodes;
      deployPkgs = import nixpkgs {
        inherit system;
        overlays = [ (import ./nix/deploy-rs-overlay.nix { inherit deploy-rs; }) ];
      };
      treefmt = import ./nix/treefmt.nix { inherit pkgs treefmt-nix; };
      pre-commit = import ./nix/pre-commit.nix {
        inherit
          system
          git-hooks
          packages
          treefmt
          ;
      };

    in
    {
      formatter.${system} = treefmt.config.build.wrapper;

      packages.${system} = {
        inherit (packages)
          render-helm
          sops-reencrypt
          bootstrap-gems
          menu
          talos-gen
          talos-iso
          ;
        default = packages.render-helm;
        installer-iso = self.nixosConfigurations.installer.config.system.build.isoImage;
      };

      devShells.${system}.default = import ./nix/shell.nix {
        inherit
          pkgs
          packages
          nodes
          system
          agenix-shell
          ;
        git-hooks = pre-commit;
        deploy-rs = deployPkgs.deploy-rs.deploy-rs;
        agenix = agenix.packages.${system}.default;
      };

      deploy.nodes.gem-gpu-0 = {
        hostname = gpuNode.ip;
        sshUser = "anthony";
        profiles.system = {
          user = "root";
          path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.gem-gpu-0;
        };
      };

      nixosConfigurations = {
        gem-gpu-0 = nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit nodes;
            node = gpuNode;
          };
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./nix/gem-gpu-0.nix
          ];
        };
        installer = nixpkgs.lib.nixosSystem { modules = [ ./nix/installer-iso.nix ]; };
      };

      checks.${system} = {
        formatting = treefmt.config.build.check self;
        pre-commit = pre-commit;
        talos-configs = import ./nix/talos-configs-check.nix { inherit pkgs nodes; };
        gem-gpu-0 = self.nixosConfigurations.gem-gpu-0.config.system.build.toplevel;
      }
      // deployPkgs.deploy-rs.lib.deployChecks self.deploy;
    };
}
