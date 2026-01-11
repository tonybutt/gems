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

      packages = import ./nix/packages.nix { inherit pkgs; };
      nodes = import ./nix/nodes.nix;
      treefmt = import ./nix/treefmt.nix { inherit pkgs treefmt-nix; };
      pre-commit = import ./nix/pre-commit.nix { inherit system git-hooks packages treefmt; };

    in
    {
      formatter.${system} = treefmt.config.build.wrapper;

      packages.${system} = {
        inherit (packages) render-helm sops-reencrypt bootstrap-gems menu talos-gen;
        default = packages.render-helm;
      };

      devShells.${system}.default = import ./nix/shell.nix {
        inherit pkgs packages nodes;
        git-hooks = pre-commit;
      };

      checks.${system} = {
        formatting = treefmt.config.build.check self;
        pre-commit = pre-commit;
      };
    };
}
