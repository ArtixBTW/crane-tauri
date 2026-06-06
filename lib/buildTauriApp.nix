{
  pkgs,
  craneLib,
}:

# RFC prototype: the build arguments are a *module* rather than a bare attrset.
# A plain attrset (`{ pname = ...; ... }`) is a valid module, so the common call
# site is unchanged — it is just type-checked now. A function
# (`{ config, ... }: { ... }`) or a list of modules also works, for composition.
#
# Build logic below is identical to the published version; only the argument
# layer changed, so the produced derivation is byte-identical (drvPath verified).
args:

let
  inherit (pkgs) lib;
  inherit (lib) types mkOption;

  optionsModule =
    { config, ... }:
    {
      options = {
        pname = mkOption {
          type = types.str;
          description = "Nix package name (and default binaryName).";
        };
        version = mkOption {
          type = types.str;
          description = "Package version.";
        };
        src = mkOption {
          type = types.path;
          description = "Repo root containing src-tauri/.";
        };
        frontend = mkOption {
          type = types.package;
          description = "Built frontend assets derivation, embedded into the app.";
        };
        binaryName = mkOption {
          type = types.str;
          default = config.pname;
          defaultText = lib.literalExpression "pname";
          description = ''
            Cargo binary name to install from target/release. Defaults to pname,
            but the on-disk binary is named by cargo ([package].name in
            src-tauri/Cargo.toml); set this when they differ.
          '';
        };
        cargoExtraArgs = mkOption {
          type = types.str;
          default = "";
          description = "Extra args appended to cargo invocations.";
        };
        cargoArtifacts = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = "Prebuilt crane deps cache to reuse instead of building one.";
        };
        cargoLock = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Explicit Cargo.lock for crane vendoring (wins over auto-detection).";
        };
        extraBuildInputs = mkOption {
          type = types.listOf types.package;
          default = [ ];
        };
        extraNativeBuildInputs = mkOption {
          type = types.listOf types.package;
          default = [ ];
        };
        extraTauriConfig = mkOption {
          type = types.attrs;
          default = { };
          description = "Extra tauri.conf.json keys, merged over the managed config.";
        };
        cargoRoot = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Closest common ancestor of src-tauri/ and sibling path-dep crates.";
        };
        extraFileset = mkOption {
          # filesets are an opaque lib value; `raw` stores it without inspection.
          type = types.nullOr types.raw;
          default = null;
          description = "Extra app-only sources (non-.rs/.toml) needed at compile time.";
        };
        craneArgs = mkOption {
          type = types.attrsOf types.anything;
          default = { };
          description = ''
            Typed escape hatch for arbitrary crane / mkDerivation args (doCheck,
            env vars, hooks, ...). Replaces the old `...`@origArgs + removeAttrs
            passthrough, so a typo at the top level is rejected by the module
            checker instead of silently leaking into the derivation.
          '';
        };
      };
    };

  # _module.check defaults to true: an unknown top-level attribute (e.g. a typo
  # like `pnmae` or `verison`) is rejected with a clear error, and a wrong type
  # (e.g. `version = 1`) fails with the option path and expected type.
  cfg =
    (lib.evalModules {
      modules = [ optionsModule ] ++ lib.toList args;
    }).config;

  inherit (cfg)
    pname
    version
    src
    frontend
    binaryName
    cargoExtraArgs
    cargoArtifacts
    extraBuildInputs
    extraNativeBuildInputs
    extraTauriConfig
    cargoRoot
    extraFileset
    ;

  tauriSrc = src + "/src-tauri";
  actualCargoRoot = if cargoRoot != null then cargoRoot else tauriSrc;
  isMonorepo = toString actualCargoRoot != toString tauriSrc;

  tauriSubdir =
    if !isMonorepo then
      "."
    else if lib.hasPrefix (toString actualCargoRoot + "/") (toString tauriSrc) then
      lib.removePrefix (toString actualCargoRoot + "/") (toString tauriSrc)
    else
      throw ''
        buildTauriApp: ${toString tauriSrc} is not under cargoRoot (${toString actualCargoRoot}).
        Set cargoRoot to a directory that contains src-tauri/. If src and
        cargoRoot come from different roots (e.g. one is a store path and
        the other is a local path), derive cargoRoot from src instead
        (e.g. `cargoRoot = src;`).'';

  cargoSources = craneLib.fileset.commonCargoSources actualCargoRoot;

  tauriExtraFiles = lib.fileset.unions [
    (tauriSrc + "/tauri.conf.json")
    (tauriSrc + "/icons")
    (lib.fileset.maybeMissing (tauriSrc + "/capabilities"))
  ];

  appFileset = lib.fileset.unions (
    [
      cargoSources
      tauriExtraFiles
    ]
    ++ lib.optional (extraFileset != null) extraFileset
  );

  appSrc = lib.fileset.toSource {
    root = actualCargoRoot;
    fileset = appFileset;
  };

  depsSrc = lib.fileset.toSource {
    root = actualCargoRoot;
    fileset = lib.fileset.difference cargoSources (
      lib.fileset.fileFilter (file: lib.hasSuffix ".rs" file.name) actualCargoRoot
    );
  };

  tauriBuildInputs =
    with pkgs;
    [
      openssl
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      webkitgtk_4_1
      libsoup_3
      gtk3
      glib
      cairo
      pango
      gdk-pixbuf
      atk
      librsvg
      libayatana-appindicator
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      libiconv
    ];

  relocateCachedTauriPaths = ''
    derivationName="''${name:-${pname}}"
    relocationFiles=0
    relocationMatches=0
    relocationRewrites=0

    log_relocation() {
      printf '%s %s\n' 'tauri-relocate:' "$*" >&2
    }

    while IFS= read -r -d "" file; do
      relocationFiles=$((relocationFiles + 1))
      while IFS= read -r oldPath; do
        if [ -z "$oldPath" ]; then
          continue
        fi

        oldSourceRoot="''${oldPath%/target/*}"

        if [ -z "$oldSourceRoot" ]; then
          continue
        fi

        relocationMatches=$((relocationMatches + 1))

        if [ -n "$oldSourceRoot" ] && [ "$oldSourceRoot" != "$PWD" ] && grep -Fq "$oldSourceRoot" "$file"; then
          substituteInPlace "$file" --replace-fail "$oldSourceRoot" "$PWD"
          relocationRewrites=$((relocationRewrites + 1))
          log_relocation "derivation=$derivationName file=$file old_root=$oldSourceRoot new_root=$PWD"
        fi
      done < <(grep -aoE "/[^[:space:]'\"]+/source/target/[^[:space:]'\"]+" "$file" | sort -u || true)
    done < <(
      find target/release/build -type f \( -name output -o -name '*-permission-files' \) -print0 2>/dev/null || true
    )

    log_relocation "derivation=$derivationName summary files=$relocationFiles matches=$relocationMatches rewrites=$relocationRewrites"
  '';

  callerSetManifestPath = lib.hasInfix "--manifest-path" cargoExtraArgs;
  manifestPathArg = lib.optionalString (
    isMonorepo && !callerSetManifestPath
  ) "--manifest-path ${tauriSubdir}/Cargo.toml";

  tauriBuildCargoExtraArgs = lib.concatStringsSep " " (
    lib.filter (s: s != "") [
      "--features tauri/custom-protocol"
      cargoExtraArgs
    ]
  );

  sharedCargoExtraArgs = lib.concatStringsSep " " (
    lib.filter (s: s != "") [
      "--features tauri/custom-protocol"
      cargoExtraArgs
      manifestPathArg
    ]
  );

  monorepoCargoLock = lib.optionalAttrs (
    isMonorepo && builtins.pathExists (tauriSrc + "/Cargo.lock")
  ) { cargoLock = tauriSrc + "/Cargo.lock"; };

  exportAbsoluteCargoTargetDir = lib.optionalString isMonorepo ''
    export CARGO_TARGET_DIR="$PWD/target"
  '';

  sharedArgs =
    monorepoCargoLock
    // cfg.craneArgs
    # The dedicated cargoLock option wins over any cargoLock buried in craneArgs.
    // lib.optionalAttrs (cfg.cargoLock != null) { cargoLock = cfg.cargoLock; }
    // {
      inherit pname version;
      strictDeps = true;
      cargoExtraArgs = sharedCargoExtraArgs;
      nativeBuildInputs = [ pkgs.pkg-config ] ++ extraNativeBuildInputs;
      buildInputs = tauriBuildInputs ++ extraBuildInputs;
      preConfigure = lib.concatStringsSep "\n" [
        exportAbsoluteCargoTargetDir
        (cfg.craneArgs.preConfigure or "")
        relocateCachedTauriPaths
      ];
    };

  commonArgs = sharedArgs // {
    src = appSrc;
  };

  resolvedCargoArtifacts =
    if cargoArtifacts != null then
      cargoArtifacts
    else
      craneLib.buildDepsOnly (sharedArgs // { src = depsSrc; });

  tauriConfig = builtins.toJSON (
    lib.recursiveUpdate {
      build = {
        frontendDist = "${frontend}";
        beforeBuildCommand = "";
      };
    } extraTauriConfig
  );

  app = craneLib.mkCargoDerivation (
    commonArgs
    // {
      cargoArtifacts = resolvedCargoArtifacts;
      TAURI_CONFIG = tauriConfig;

      nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ pkgs.cargo-tauri ];

      buildPhaseCargoCommand = ''
        cargo tauri build --no-bundle \
          ${tauriBuildCargoExtraArgs} \
          --config "$TAURI_CONFIG"
      '';

      installPhaseCommand = ''
        binaryPath=$(find target -type f -path ${lib.escapeShellArg "*/release/${binaryName}"} -print -quit)

        if [ -z "$binaryPath" ]; then
          echo "failed to locate built binary ${binaryName}" >&2
          exit 1
        fi

        mkdir -p $out/bin
        cp "$binaryPath" $out/bin/
      '';

      doInstallCargoArtifacts = false;
    }
  );
in
{
  inherit
    app
    frontend
    commonArgs
    tauriConfig
    tauriSubdir
    ;
  cargoArtifacts = resolvedCargoArtifacts;
}
