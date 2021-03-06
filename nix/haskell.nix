############################################################################
# Builds Haskell packages with Haskell.nix
############################################################################
{ lib
, stdenv
, pkgs
, haskell-nix
, buildPackages
, config ? {}
# GHC attribute name
, compiler ? config.haskellNix.compiler or "ghc865"
# Enable profiling
, profiling ? config.haskellNix.profiling or false
, libsodium ? pkgs.libsodium
}:
let

  src = haskell-nix.haskellLib.cleanGit {
      name = "ouroboros-network-src";
      src = ../.;
  };

  projectPackages = lib.attrNames (haskell-nix.haskellLib.selectProjectPackages
    (haskell-nix.cabalProject { inherit src; }));

  # This creates the Haskell package set.
  # https://input-output-hk.github.io/haskell.nix/user-guide/projects/
  pkgSet = haskell-nix.cabalProject {
    inherit src;
    compiler-nix-name = compiler;
    modules = [

      # Allow reinstallation of Win32
      { nonReinstallablePkgs =
        [ "rts" "ghc-heap" "ghc-prim" "integer-gmp" "integer-simple" "base"
          "deepseq" "array" "ghc-boot-th" "pretty" "template-haskell"
          # ghcjs custom packages
          "ghcjs-prim" "ghcjs-th"
          "ghc-boot"
          "ghc" "array" "binary" "bytestring" "containers"
          "filepath" "ghc-boot" "ghc-compact" "ghc-prim"
          # "ghci" "haskeline"
          "hpc"
          "mtl" "parsec" "text" "transformers"
          "xhtml"
          # "stm" "terminfo"
        ];
      }
      # Compile all local packages with -Werror:
      {
        packages = lib.genAttrs projectPackages
          (name: { configureFlags = [ "--ghc-option=-Werror" ]; });
      }
      {
        packages.katip.components.library.doExactConfig = true;
        packages.prometheus.components.library.doExactConfig = true;
        enableLibraryProfiling = profiling;
      }
      (if stdenv.hostPlatform.isWindows then {
        # Disable cabal-doctest tests by turning off custom setups
        packages.comonad.package.buildType = lib.mkForce "Simple";
        packages.distributive.package.buildType = lib.mkForce "Simple";
        packages.lens.package.buildType = lib.mkForce "Simple";
        packages.nonempty-vector.package.buildType = lib.mkForce "Simple";
        packages.semigroupoids.package.buildType = lib.mkForce "Simple";
        packages.system-filepath.package.buildType = lib.mkForce "Simple";

        # ruby/perl dependencies cannot be cross-built for cddl tests:
        packages.ouroboros-network.flags.cddl = false;

        # Make sure we use a buildPackages version of happy
        packages.pretty-show.components.library.build-tools = [ buildPackages.haskell-nix.haskellPackages.happy ];

        # Remove hsc2hs build-tool dependencies (suitable version will be available as part of the ghc derivation)
        packages.Win32.components.library.build-tools = lib.mkForce [];
        packages.terminal-size.components.library.build-tools = lib.mkForce [];
        packages.network.components.library.build-tools = lib.mkForce [];

        # Make sure that libsodium DLLs are available for tests
        packages.ouroboros-consensus-shelley-test.components.all.postInstall = lib.mkForce "";
        packages.ouroboros-consensus-shelley-test.components.tests.test.postInstall = ''ln -s ${libsodium}/bin/libsodium-23.dll $out/bin/libsodium-23.dll'';
        packages.ouroboros-consensus-cardano.components.all.postInstall = lib.mkForce "";
        packages.ouroboros-consensus-cardano.components.tests.test.postInstall = ''ln -s ${libsodium}/bin/libsodium-23.dll $out/bin/libsodium-23.dll'';
      } else {
        packages.ouroboros-network.flags.cddl = true;
        packages.ouroboros-network.components.tests.test-cddl.build-tools = [pkgs.cddl pkgs.cbor-diag];
        packages.ouroboros-network.components.tests.test-cddl.preCheck = "export HOME=`pwd`";
      })
    ];
    configureArgs = lib.optionalString stdenv.hostPlatform.isWindows "--disable-tests";
  };
in
  pkgSet
