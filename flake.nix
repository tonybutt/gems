{
  description = "Flake for gwctl";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    devenv.url = "github:cachix/devenv";
  };

  outputs = inputs@{ self, flake-parts, devenv, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        devenv.flakeModule
      ];
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      perSystem = { pkgs, lib, config, system, ... }: {
        devenv.shells.default =
          let
            menu = ''
              echo
              echo 🦾 Command Menu:
              echo 🦾
              ${pkgs.gnused}/bin/sed -e 's| |••|g' -e 's|=| |' <<EOF | ${pkgs.util-linuxMinimal}/bin/column -t | ${pkgs.gnused}/bin/sed -e 's|^|🦾 |' -e 's|••| |g'
              ${lib.generators.toKeyValue {} (lib.mapAttrs (name: value: value.description) config.devenv.shells.default.scripts)}
              EOF
              echo
            '';
            template-helm = pkgs.writeShellApplication {
              name = "generate-helm-manifests";
              text = ''
                set -e

                VALUES_FILE="./clusters/gems/platform/cilium/helm-values.yaml"
                OUTPUT_FILE="./clusters/gems/platform/cilium/cilium.yaml"
                TEMP_FILE=$(mktemp)

                ${pkgs.kubernetes-helm}/bin/helm template cilium cilium/cilium --version 1.16.3 -f "$VALUES_FILE" > "$TEMP_FILE"

                if cmp -s "$TEMP_FILE" "$OUTPUT_FILE"; then
                    echo "No changes in Kubernetes manifests."
                else
                    echo "Updating Kubernetes manifests."
                    mv "$TEMP_FILE" "$OUTPUT_FILE"
                fi

                [ -f "$TEMP_FILE" ] && rm "$TEMP_FILE"

                exit 0
              '';
            };
          in
          {
            packages = [ pkgs.talosctl pkgs.kubernetes-helm ];

            scripts = {
              menu = {
                exec = menu;
                description = "Show the menu of commands";
              };
              dashboard = {
                exec = ''
                  talosctl -n 192.168.86.250 dashboard
                '';
                package = pkgs.talosctl;
                description = "Cluster Dashboard";
              };
              generate-cilium-manifests = {
                exec = ''${template-helm}/bin/generate-helm-manifests'';
                description = "Generates Cilium manifests from helm chart";
              };
            };

            git-hooks.hooks = {
              nixpkgs-fmt.enable = true;
              generate-cilium-manifests = {
                enable = true;
                files = "helm-values\.yaml$";
                entry = "${template-helm}/bin/generate-helm-manifests";
                pass_filenames = true;
              };
            };

            enterShell = menu;
          };
      };
    };
}
