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
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      git-hooks,
      disko,
      agenix,
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
        inherit pkgs packages nodes;
        git-hooks = pre-commit;
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
      };
    };
}
