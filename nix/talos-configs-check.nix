{ pkgs, nodes }:
let
  inherit (pkgs.lib)
    concatMap
    concatMapStrings
    escapeShellArgs
    filter
    optionals
    optionalString
    ;

  patch = path: [
    "--config-patch"
    "@${path}"
  ];

  genArgs =
    node:
    [
      nodes.cluster.name
      nodes.cluster.endpoint
      "--with-secrets"
      "secrets.yaml"
      "--install-image"
      "factory.talos.dev/metal-installer/${nodes.schematic}:v${nodes.versions.talos}"
      "--kubernetes-version"
      nodes.versions.kubernetes
    ]
    ++ patch ../talos/patches/base.yaml
    ++ optionals (node.type == "controlplane") (
      concatMap patch [
        ../talos/patches/controlplane-delete-node.yaml
        ../talos/patches/controlplane.yaml
      ]
    )
    ++ patch (../talos/nodes + "/${node.name}.yaml")
    ++ [
      "--output-types"
      node.type
      "-o"
      "${node.name}.yaml"
    ];

  doc = kind: file: "awk '/^kind: ${kind}$/{p=1} /^---$/{p=0} p' ${file}";

  validateNode = node: ''
    talosctl gen config ${escapeShellArgs (genArgs node)}
    talosctl validate -c ${node.name}.yaml -m metal
    ${doc "UserVolumeConfig" "${node.name}.yaml"} | grep -q '^name: openebs-local\b'
    ${optionalString (node.type == "controlplane") ''
      ${doc "KubeProxyConfig" "${node.name}.yaml"} | grep -q '^enabled: false\b'
    ''}
    ! grep -qx 'kind: KubeFlannelCNIConfig' ${node.name}.yaml
    ! ${doc "KubeNodeConfig" "${node.name}.yaml"} | grep -q 'NoSchedule'
    ${doc "SecurityProfileConfig" "${node.name}.yaml"} | grep -q '^workloadIsolation: false\b'
    ${doc "UnattendedInstallConfig" "${node.name}.yaml"} | grep -q '/dev/nvme0n1'
  '';
in
pkgs.runCommand "talos-configs" { nativeBuildInputs = [ pkgs.talosctl ]; } ''
  export HOME="$TMPDIR"
  talosctl gen secrets -o secrets.yaml
  ${concatMapStrings validateNode (filter (n: n.os == "talos") nodes.nodes)}
  touch "$out"
''
