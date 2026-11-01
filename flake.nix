{
  # The tools ct's checks need, versioned with ct: `just check` (lint and the bats suite) runs in
  # this shell locally (`direnv exec . just check`) and in CI (`nix develop -c just check`), so
  # both use the same shellcheck. ct itself needs none of them installed: it is plain bash.
  description = "ct's development shell";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/release-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.bats
            pkgs.shellcheck
            pkgs.just
            pkgs.perl
            pkgs.jq
            pkgs.git
            pkgs.coreutils
            pkgs.findutils
            pkgs.python3
          ];
        };
      });
    };
}
