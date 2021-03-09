# This file is used by nix-shell.
# It just takes the shell attribute from default.nix.
{ config ? { compiler = "ghc8104"; }
, sourcesOverride ? { }
, withHoogle ? false
, pkgs ? import ./nix {
    inherit config sourcesOverride;
  }
}:
with pkgs;
let
  stylish-haskell = import ./nix/stylish-haskell.nix { inherit pkgs config; };
  # This provides a development environment that can be used with nix-shell or
  # lorri. See https://input-output-hk.github.io/haskell.nix/user-guide/development/
  # NOTE: due to some cabal limitation,
  #  you have to remove all `source-repository-package` entries from cabal.project
  #  after entering nix-shell for cabal to use nix provided dependencies for them.
  shell = ouroborosNetworkHaskellPackages.shellFor {
    name = "cabal-dev-shell";

    packages = ps: lib.attrValues (haskell-nix.haskellLib.selectProjectPackages ps)
                ++ [ ps.cardano-crypto-class ];

    # These programs will be available inside the nix-shell.
    buildInputs = [
      stylish-haskell
      niv
      pkgconfig
    ];

    tools = {
      ghcid = "0.8.7";
      cabal = "3.2.0.0";
      # todo: add back the build tools which are actually necessary
      # ghcide = "0.2.0";
      # hlint = "...";
    };

    # Prevents cabal from choosing alternate plans, so that
    # *all* dependencies are provided by Nix.
    exactDeps = true;

    inherit withHoogle;
  };

  devops = pkgs.stdenv.mkDerivation {
    name = "devops-shell";
    buildInputs = [
      niv
    ];
    shellHook = ''
      echo "DevOps Tools" \
      | ${figlet}/bin/figlet -f banner -c \
      | ${lolcat}/bin/lolcat

      echo "NOTE: you may need to export GITHUB_TOKEN if you hit rate limits with niv"
      echo "Commands:
        * niv update <package> - update package

      "
    '';
  };

in

 shell // { inherit devops; }
