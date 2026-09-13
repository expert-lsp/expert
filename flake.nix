{
  description = "Reimagined language server for Elixir";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    beam-flakes.url = "github:elixir-tools/nix-beam-flakes";
    beam-flakes.inputs.flake-parts.follows = "flake-parts";
    beam-flakes.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.beam-flakes.flakeModule ];

      systems = [
        "x86_64-darwin"
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { lib, pkgs, ... }:
        let
          beamPackages = pkgs.beamMinimal27Packages.overrideScope (_: prev: { elixir = prev.elixir_1_17; });
        in
        {
          formatter = pkgs.nixfmt;

          apps.update-deps =
            let
              script = pkgs.writeShellApplication {
                name = "update-deps";

                runtimeInputs = [
                  beamPackages.elixir
                  pkgs.just
                ];

                text = ''
                  just mix all deps.get
                  just mix all deps.nix
                '';
              };
            in
            {
              type = "app";
              program = lib.getExe script;
            };

          packages = rec {
            default = expert;

            expert = pkgs.callPackage ./nix/expert.nix { inherit beamPackages; };
          };

          beamWorkspace = {
            enable = true;
            devShell.languageServers.elixir = false;
            devShell.languageServers.erlang = false;
            versions = {
              elixir = "1.17.3";
              erlang = "27.3.4.1";
            };
            devShell.extraPackages = with pkgs; [
              nixfmt
              zig_0_15
              xz
              just
              _7zz
              git
              zizmor
            ];
          };
        };
    };
}
