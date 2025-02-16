{
  description = "Flake for gems";

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
            nodes = [
              {
                name = "gem-worker-1";
                ip = "192.168.86.33";
              }
              {
                name = "gem-master-2";
                ip = "192.168.86.31";
              }
              {
                name = "gem-master-0";
                ip = "192.168.86.250";
              }
              {
                name = "gem-master-1";
                ip = "192.168.86.21";
              }
              {
                name = "gem-worker-0";
                ip = "192.168.86.25";
              }
            ];
            upgrade-scripts = builtins.listToAttrs (map
              (node: {
                name = "upgrade-${node.name}";
                value = {
                  exec = ''${pkgs.talosctl}/bin/talosctl upgrade --image "ghcr.io/siderolabs/installer:v$1" -n ${node.ip}'';
                  description = "Upgrade ${node.name} <command> <version> (e.g. upgrade-${node.name} 1.9.3)";
                };
              })
              nodes);
            apply-config-scripts = builtins.listToAttrs (map
              (node:
                let
                  nodeType = if lib.strings.hasInfix "master" node.name then "controlplane" else "worker";
                  nodeDir = "infrastructure/nodes";
                in
                {
                  name = "apply-${node.name}";
                  value = {
                    exec = ''${pkgs.talosctl}/bin/talosctl apply-config -n ${node.ip} --file infrastructure/${nodeType}.yaml -p @${nodeDir}/${node.name}.yaml -p @${nodeDir}/base-patches.yaml'';
                    description = "Apply config for ${node.name}";
                  };
                })
              nodes);
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
              runtimeInputs = with pkgs; [ kubernetes-helm ];
              text = builtins.readFile ./scripts/generate-cilium-manifests.sh;
            };
            bootstrap-gems = pkgs.writeShellApplication {
              name = "bootstrap-gems";
              runtimeInputs = with pkgs; [ talosctl kubectl kustomize sops ];
              text = builtins.readFile ./scripts/bootstrap-gems.sh;
            };
          in
          {
            env.TALOSCONFIG = "infrastructure/talosconfig";
            packages = with pkgs; [ talosctl kubernetes-helm cloudflared kubectl kustomize sops ];

            scripts = upgrade-scripts // apply-config-scripts // {
              menu = {
                exec = menu;
                description = "Show the menu of commands";
              };
              generate-cilium-manifests = {
                exec = ''${template-helm}/bin/generate-helm-manifests'';
                description = "Generates Cilium manifests from helm chart";
              };
              bootstrap-gems = {
                exec = ''${bootstrap-gems}/bin/bootstrap-gems'';
                description = "Bootstraps the gems cluster";
              };
              kubeconfig = {
                exec = ''${pkgs.talosctl}/bin/talosctl kubeconfig -n 192.168.86.250 -e 192.168.86.250 --context gems --talosconfig=./clusters/gems/infra/talosconfig'';
                description = "Get kubeconfig for the gems cluster";
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
