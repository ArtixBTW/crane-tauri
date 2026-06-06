{
  description = "Build Tauri v2 apps with crane dependency caching";

  inputs = { };

  outputs =
    { ... }:
    {
      lib.buildTauriApp = import ./lib/buildTauriApp.nix;

      templates.default = {
        description = "Tauri v2 app with Nix build using crane-tauri";
        path = ./templates/default;
        welcomeText = ''
          # crane-tauri template

          This template provides only the Nix glue (`flake.nix`). It expects an
          existing Tauri v2 project in the same directory: the frontend sources
          (`package.json`, `src/`, `index.html`, ...) and `src-tauri/`. If you
          don't have one yet, scaffold it first (e.g. `npm create tauri-app`).

          Next:
          1. set `pname` / `version`
          2. build once to get the real `npmDepsHash` (Nix prints the expected
             value on the first failed build) and paste it in
          3. `nix build` to produce the app; `nix flake check` to run clippy/fmt
        '';
      };
    };
}
