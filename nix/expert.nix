{
  beamPackages,
  callPackages,
  lib,
}:
let
  version = builtins.readFile ../version.txt;

  engineDeps = callPackages ../apps/engine/deps.nix {
    inherit lib beamPackages;
    # elixir_sense ships a yecc grammar (src/elixir_sense_parser.yrl). Mix normally
    # compiles it into src/elixir_sense_parser.erl, but at runtime the engine builds
    # against these sources straight from the read-only Nix store, so that in-tree
    # write fails. Pre-generate the parser so Mix finds it and skips regenerating
    # (Nix zeroes mtimes, so the .erl is never considered stale relative to the .yrl).
    #
    # This lives here, in deps.nix's `overrides` hook, rather than in deps.nix itself
    # so it survives `nix run .#update-deps` regenerating that file.
    overrides = _final: prev: {
      elixir_sense = prev.elixir_sense.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          grammar="$out/src/src/elixir_sense_parser.yrl"
          if [ -f "$grammar" ]; then
            chmod -R u+w "$out/src/src"
            ${beamPackages.erlang}/bin/erlc -o "$out/src/src" "$grammar"
            test -f "$out/src/src/elixir_sense_parser.erl"
          fi
        '';
      });
    };
  };
in
beamPackages.mixRelease rec {
  pname = "expert";
  inherit version;

  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ../apps
      ../mix_credo.exs
      ../mix_dialyzer.exs
      ../mix_includes.exs
      ../version.txt
    ];
  };

  mixNixDeps = callPackages ../apps/expert/deps.nix { inherit lib beamPackages; };

  mixReleaseName = "plain";

  preConfigure = ''
    # copy the logic from mixRelease to build a deps dir for engine
    mkdir -p apps/engine/deps
    ${lib.concatMapAttrsStringSep "\n" (name: dep: ''
      dep_path="apps/engine/deps/${name}"
      if [ -d "${dep}/src" ]; then
        ln -sv ${dep}/src $dep_path
      fi
    '') engineDeps}

      cd apps/expert
  '';

  postInstall = ''
    rm "$out/bin/start_expert"
    mv $out/bin/plain $out/bin/expert
    wrapProgram $out/bin/expert --add-flag "eval" --add-flag "System.no_halt(true); Application.ensure_all_started(:xp_expert)"
  '';

  removeCookie = false;

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test "$(ls "$out/bin")" = expert
    test -x "$out/bin/expert"
    runHook postInstallCheck
  '';

  passthru = {
    # not used by package, but exposed for repl and direct build access
    # e.g. nix build .#expert.mixNixDeps.jason
    inherit engineDeps mixNixDeps;
  };

  meta.mainProgram = "expert";
}
