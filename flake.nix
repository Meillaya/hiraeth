{
  description = "Hiraeth local development environment";

  # devenv.cachix.org binary cache (devenv default) trusted for local nix use.
  nixConfig = {
    extra-substituters = [ "https://devenv.cachix.org" ];
    extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    devenv.url = "github:cachix/devenv/8f297eae651cb47fb1e8f7c19b942462aa879636";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, devenv, ... }@inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              ({ ... }: {
                # Flake checks use pure evaluation, so devenv cannot infer the
                # current directory. Pin the root to this flake source for
                # reproducible evaluation; interactive shells still enter from
                # the caller's worktree.
                devenv.root = builtins.toString ./.;
              })
              ./devenv.nix
            ];
          };
        });
    };
}
