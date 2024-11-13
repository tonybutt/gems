{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    talhelper.url = "github:budimanjojo/talhelper";
  };

  outputs =
    {
      self,
      nixpkgs,
      talhelper,
    }:
    let
      allSystems = [
        "x86_64-linux" # 64-bit Intel/AMD 
        "aarch64-linux" # 64-bit ARM 
        "x86_64-darwin" # 64-bit Intel macOS
        "aarch64-darwin" # 64-bit ARM macOS
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs allSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { 
              inherit system;
              overlays = [
                talhelper.overlays.default
              ];
            };
          }
        );
    in
    {
      devShell = forAllSystems (
        { system, pkgs }:
        pkgs.mkShell {
          packages = with pkgs; [
            rage
            talosctl
            timoni
            flux
            sops
            pkgs.talhelper
          ];
        }
      );
    };
}
