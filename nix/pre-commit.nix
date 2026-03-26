# Git hooks configuration
{
  system,
  git-hooks,
  treefmt,
  packages,
}:

git-hooks.lib.${system}.run {
  src = ../.;
  hooks = {
    treefmt = {
      enable = true;
      package = treefmt.config.build.wrapper;
      entry = "${treefmt.config.build.wrapper}/bin/treefmt --fail-on-change";
    };
    render-helm = {
      enable = true;
      name = "render-helm";
      entry = "${packages.render-helm}/bin/render-helm";
      files = "helm-values\\.yaml$";
      pass_filenames = true;
    };
    validate-kustomize = {
      enable = true;
      name = "validate-kustomize";
      entry = "${packages.validate-kustomize}/bin/validate-kustomize";
      files = "kustomization\\.yaml$|\\.yaml$";
      pass_filenames = false;
      always_run = true;
    };
    commitizen.enable = true;
  };
}
