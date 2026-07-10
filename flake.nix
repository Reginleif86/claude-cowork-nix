{
  description = "Claude Desktop for Linux - fully declarative NixOS package with Cowork support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Claude Desktop version and source
      claudeVersion = "1.20186.0";
      claudeDmgHash = "sha256-y0K4Eexp7FVFD22p50PYzZaHOtJdAVe6pqS+nNFxWvc=";
      claudeDmgUrl = "https://downloads.claude.ai/releases/darwin/universal/1.20186.0/Claude-d7731e7f42fb72db87a6488ad8c1357b1cf971f7.dmg";

      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      forEachSystem = f: builtins.listToAttrs (map (system: {
        name = system;
        value = f system;
      }) supportedSystems);

      # Per-pkgs builder factory. Takes a nixpkgs instance and returns the
      # set of derivations and package-builder functions. Shared between
      # `packages` (built from the flake's nixpkgs) and the NixOS / Home
      # Manager modules (built from the user's nixpkgs). This lets the
      # modules rebuild the wrapper with a user-supplied `claudeCodePackage`
      # without re-implementing the wrapper logic.
      mkBuildersFor = pkgs:
        let
          # Fetch macOS DMG
          claudeSrc = pkgs.fetchurl {
            url = claudeDmgUrl;
            hash = claudeDmgHash;
          };

          # Python ASAR tool
          asarTool = pkgs.writeScriptBin "asar-tool" ''
            #!${pkgs.python3}/bin/python3
            ${builtins.readFile ./tools/asar_tool.py}
          '';

          # Linux-native node-pty addon (pty.node) for the in-app terminal/shell PTY.
          # The DMG ships only a macOS Mach-O pty.node, so on Linux node-pty fails to
          # load ("Cannot find module .../pty.node") and the shell PTY is dead. node-pty
          # 1.1.0-beta34 uses node-addon-api (N-API, ABI-stable), so a binary built
          # against electron_41's headers loads in the runtime. spawn-helper is macOS-
          # only (gyp OS=="mac"; pty.cc execs it under __APPLE__) — Linux forks directly.
          nodePtyElectron = pkgs.stdenv.mkDerivation {
            pname = "node-pty-electron";
            version = "1.1.0-beta34";
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/node-pty/-/node-pty-1.1.0-beta34.tgz";
              hash = "sha256-LxvUoachiyWC2M3hxxTDZ6InsdLuKwjLrJ+gM4GdWeQ=";
            };
            nodeAddonApi = pkgs.fetchurl {
              url = "https://registry.npmjs.org/node-addon-api/-/node-addon-api-7.1.1.tgz";
              hash = "sha256-sQRV0VqXfAzRehyw62eeA9k5+O+NQwLrM+H3jazHH4I=";
            };
            nativeBuildInputs = [ pkgs.nodejs pkgs.node-gyp pkgs.python3 pkgs.gnumake pkgs.gcc ];
            configurePhase = ''
              runHook preConfigure
              export HOME=$TMPDIR
              export npm_config_nodedir=${pkgs.electron_41.headers}
              mkdir -p node_modules/node-addon-api
              tar xzf $nodeAddonApi -C node_modules/node-addon-api --strip-components=1
              node-gyp configure --nodedir=${pkgs.electron_41.headers} --arch=x64
              runHook postConfigure
            '';
            buildPhase = ''
              runHook preBuild
              node-gyp build --nodedir=${pkgs.electron_41.headers} --arch=x64
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp build/Release/pty.node $out/pty.node
              runHook postInstall
            '';
          };

          # Extract app.asar from DMG and apply patches
          claudeApp = pkgs.stdenv.mkDerivation {
            pname = "claude-desktop-app";
            version = claudeVersion;

            src = claudeSrc;

            nativeBuildInputs = with pkgs; [
              _7zz
              python3
              nodejs
              perl
            ];

            dontUnpack = true;

            buildPhase = ''
              runHook preBuild

              echo "=== Extracting Claude Desktop ${claudeVersion} ==="

              # Extract directly from DMG using 7zz (supports LZFSE natively)
              echo "[1/6] Extracting DMG..."
              mkdir -p dmg-contents
              7zz x -y -odmg-contents $src > /dev/null 2>&1

              # Find app.asar
              echo "[2/6] Locating app.asar..."
              APP_ASAR=$(find dmg-contents -name "app.asar" -path "*/Contents/Resources/*" | head -1)
              if [ -z "$APP_ASAR" ]; then
                echo "ERROR: app.asar not found in DMG"
                find dmg-contents -name "*.asar" || true
                exit 1
              fi
              echo "  Found: $APP_ASAR"

              # Also grab app.asar.unpacked if it exists
              APP_UNPACKED="$(dirname "$APP_ASAR")/app.asar.unpacked"

              # Locate the Resources directory (contains i18n, icons, etc.)
              RESOURCES_DIR="$(dirname "$APP_ASAR")"
              echo "  Resources dir: $RESOURCES_DIR"

              # Extract ASAR
              echo "[3/6] Extracting ASAR..."
              mkdir -p extracted
              ${asarTool}/bin/asar-tool extract "$APP_ASAR" extracted

              # Copy i18n resources into ASAR tree
              # The app looks for resources/i18n/*.json relative to the ASAR root
              echo "  Copying i18n resources..."
              mkdir -p extracted/resources/i18n
              for json in "$RESOURCES_DIR"/*.json; do
                if [ -f "$json" ]; then
                  cp "$json" extracted/resources/i18n/
                fi
              done
              echo "  Copied $(ls extracted/resources/i18n/*.json 2>/dev/null | wc -l) i18n files"

              # Copy tray icons directly into resources/ (not resources/icons/)
              # The app resolves icon paths via path.resolve(__dirname, "../..", "resources")
              echo "  Copying tray icons..."
              for icon in "$RESOURCES_DIR"/TrayIcon*.png "$RESOURCES_DIR"/Tray-Win32*.ico "$RESOURCES_DIR"/EchoTray*.png; do
                if [ -f "$icon" ]; then
                  cp "$icon" extracted/resources/
                fi
              done
              echo "  Copied $(ls extracted/resources/TrayIcon* extracted/resources/EchoTray* extracted/resources/Tray-Win32* 2>/dev/null | wc -l) tray icons"

              # Extract app icon from ICNS for notification icon and desktop entry
              echo "  Extracting app icons from ICNS..."
              ICNS_FILE="$RESOURCES_DIR/electron.icns"
              if [ -f "$ICNS_FILE" ]; then
                mkdir -p icon-extracted
                ${pkgs.python3}/bin/python3 ${./tools/icns_extract.py} "$ICNS_FILE" icon-extracted
                # Place 256px icon in ASAR resources as icon.png (used for notifications)
                if [ -f icon-extracted/256.png ]; then
                  cp icon-extracted/256.png extracted/resources/icon.png
                  echo "  Installed icon.png (256x256) for notifications"
                elif [ -f icon-extracted/512.png ]; then
                  cp icon-extracted/512.png extracted/resources/icon.png
                  echo "  Installed icon.png (512x512) for notifications"
                fi
              else
                echo "  WARNING: electron.icns not found, skipping app icon extraction"
              fi

              # Copy plugin permission shim into resources/
              echo "  Installing plugin permission shim..."
              cp ${./scripts/cowork-plugin-shim.sh} extracted/resources/cowork-plugin-shim.sh
              chmod +x extracted/resources/cowork-plugin-shim.sh
              echo "  Done"

              # Apply patches (version-resilient regex + dynamic discovery)
              echo "[4/6] Applying patches..."

              INDEX="extracted/.vite/build/index.js"
              MAINVIEW="extracted/.vite/build/mainView.js"

              # --- Patch 00: Native module stub ---
              echo "[patch:00] Installing native module stub..."
              mkdir -p extracted/node_modules/@ant/claude-native
              cp ${./modules/enhanced-claude-native-stub.js} extracted/node_modules/@ant/claude-native/index.js
              cat > extracted/node_modules/@ant/claude-native/package.json <<STUBPKG
              {"name":"@ant/claude-native","version":"1.0.0-linux-stub","main":"index.js"}
              STUBPKG
              echo "[patch:00] Done"

              # --- Patch 01: Cowork module loader ---
              echo "[patch:01] Installing cowork module..."
              mkdir -p extracted/node_modules/claude-cowork-linux
              cp ${./modules/claude-cowork-linux.js} extracted/node_modules/claude-cowork-linux/index.js
              cat > extracted/node_modules/claude-cowork-linux/package.json <<COWORKPKG
              {"name":"claude-cowork-linux","version":"2.0.0","main":"index.js"}
              COWORKPKG
              cat ${./scripts/cowork-init.js} >> "$INDEX"
              echo "[patch:01] Done"

              # --- Patch 02: RETIRED in v1.13576.4 ---
              # Old role: flip the inlined `_o=process.platform==="win32"` boolean
              # true on Linux to (a) mark the platform supported and (b) select the
              # TS vmClient path. v1.13576.4 removed that boolean pair entirely:
              #   - VM-implementation selection is gone (always loads @ant/claude-swift;
              #     patches 06a/06b substitute the Linux VM via the qo()/f_t() getters).
              #   - Cowork availability moved into one unified function (codename
              #     "yukonSilver"), now handled by patch 03.
              # No single flag remains to flip, so this patch is a no-op.
              echo "[patch:02] Skipped (obsolete in v1.13576.4 — role absorbed by patches 03 + 06)"

              # --- Patch 03: Cowork availability (regex) ---
              # v1.13576.4 unified Cowork availability into a single function
              # (codename "yukonSilver", minified e.g. `Hce`) shaped as:
              #   function X(){const a=S8i();if(a)return a;if(b)return b;
              #                const c=w8i();if(c.status!=="supported")return ...}
              # The old `const t=process.platform;if(t!=="darwin"&&t!=="win32")
              # return{status:"unsupported"}` shape is gone. Inject a Linux
              # "supported" early-return at the top of that function. This also
              # subsumes old patch 02's availability role (the darwin/win32 boolean
              # pair that fed availability was inlined away in this refactor).
              # Anchor on the structural prefix (unique); function name may contain
              # `$`, so match with [\w\$]+. Local names vary — use \w+.
              echo "[patch:03] Patching Cowork availability..."
              perl -i -pe 's{(function )([\w\$]+)(\(\)\{)(const \w+=\w+\(\);if\(\w+\)return \w+;if\(\w+\)return \w+;const \w+=\w+\(\);if\(\w+\.status!=="supported")}{$1$2$3if(process.platform==="linux"\&\&global.__linuxCowork)return\{status:"supported"\};$4}g' "$INDEX"
              grep -qP 'if\(process\.platform==="linux"&&global\.__linuxCowork\)return\{status:"supported"\}' "$INDEX" \
                || { echo "ERROR: patch 03 (Cowork availability) failed to apply"; exit 1; }
              echo "[patch:03] Done"

              # --- Patch 04: Skip download (regex) ---
              # Skips macOS VM bundle download on Linux
              # Parameter names vary across versions (t,e / e,A / ...) — use \w+.
              echo "[patch:04] Patching download skip..."
              perl -i -pe 's{(async function \w+\(\w+,\w+\)\{)(.{0,200}?\[downloadVM\])}{$1if(process.platform==="linux"\&\&global.__linuxCowork){console.log("[Cowork Linux] Skipping bundle download");return!1}$2}g' "$INDEX"
              grep -qP 'async function \w+\(\w+,\w+\)\{if\(process\.platform==="linux"' "$INDEX" \
                || { echo "ERROR: patch 04 (skip download) failed to apply"; exit 1; }
              echo "[patch:04] Done"

              # --- Patch 05: VM start intercept (dynamic Node.js) ---
              # Discovers function name via [VM:start] log string, injects bubblewrap session
              echo "[patch:05] Patching VM start intercept..."
              ${pkgs.nodejs}/bin/node ${./scripts/patch-vm-start.js} extracted
              echo "[patch:05] Done"

              # --- Patch 06a: VM getter (regex) ---
              # Returns Linux VM instance from getter function
              echo "[patch:06a] Patching VM getter..."
              perl -i -pe 's{(async function )(\w+)(\(\)\{)(const \w+=await \w+\(\);return\(\w+==null\?void 0:\w+\.vm\)\?\?null)}{$1$2$3if(process.platform==="linux"\&\&global.__linuxCowork\&\&global.__linuxCowork.vmInstance){console.log("[Cowork Linux] $2() returning Linux VM");return global.__linuxCowork.vmInstance}$4}g' "$INDEX"
              grep -qP '\[Cowork Linux\] \w+\(\) returning Linux VM' "$INDEX" \
                || { echo "ERROR: patch 06a (VM getter) failed to apply"; exit 1; }
              echo "[patch:06a] Done"

              # --- Patch 06b: Platform getter (regex) ---
              # Don't return null for Linux in platform-gated getter
              echo "[patch:06b] Patching platform getter..."
              perl -i -pe 's{(async function [\w\$]+\(\)\{return )process\.platform!=="darwin"\?null(:await \w+\(\))}{''${1}process.platform!=="darwin"\&\&process.platform!=="linux"?null''${2}}g' "$INDEX"
              grep -qP 'process\.platform!=="darwin"&&process\.platform!=="linux"\?null' "$INDEX" \
                || { echo "ERROR: patch 06b (platform getter) failed to apply"; exit 1; }
              echo "[patch:06b] Done"

              # --- Patch 07: Platform branding ---
              echo "[patch:07] Injecting platform branding fix..."
              cat ${./scripts/branding-fix.js} >> "$MAINVIEW"
              echo "[patch:07] Done"

              # --- Patch 08a: Tray icon resource path (regex) ---
              # Returns real filesystem path on Linux (COSMIC SNI can't read from ASAR)
              echo "[patch:08a] Patching tray icon resource path..."
              perl -i -pe 's{function ([\w\$]+)\(\)\{return ([\w\$]+)\.app\.isPackaged\?([\w\$]+)\.resourcesPath:([\w\$]+)\.resolve\(__dirname,"\.\.","\.\.","resources"\)\}}{function $1(){return process.platform==="linux"?$4.join($4.dirname($2.app.getAppPath()),"resources"):$2.app.isPackaged?$3.resourcesPath:$4.resolve(__dirname,"..","..","resources")}}g' "$INDEX"
              grep -qP 'process\.platform==="linux"\?\w+\.join\(\w+\.dirname\(' "$INDEX" \
                || { echo "ERROR: patch 08a (tray icon path) failed to apply"; exit 1; }
              echo "[patch:08a] Done"

              # --- Patch 08b: Tray icon filename (regex) ---
              # v1.13576.4 replaced the old platform ternary with a switch on a
              # build-time icon-type const (`OJr="template-image"`):
              #   switch(t){case"ico":...Tray-Win32...;
              #             case"template-image":e="TrayIconTemplate.png";break;
              #             case"png":e=dark?"TrayIconTemplate-Dark.png":"...";break}
              # On Linux the "template-image" case yields a non-theme-aware PNG and
              # COSMIC's SNI can't do macOS-style template inversion, so make that
              # case pick the dark variant when the system theme is dark. The
              # electron namespace var (e.g. cA) is captured from the "ico" case.
              echo "[patch:08b] Patching tray icon filename selection..."
              perl -i -pe 's{(case"ico":e=(\w+)\.nativeTheme\.shouldUseDarkColors\?"Tray-Win32-Dark\.ico":"Tray-Win32\.ico";break;case"template-image":e=)"TrayIconTemplate\.png"(;break)}{$1process.platform==="linux"\&\&$2.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"$3}g' "$INDEX"
              grep -qP 'case"template-image":e=process\.platform==="linux"&&\w+\.nativeTheme\.shouldUseDarkColors\?"TrayIconTemplate-Dark\.png":"TrayIconTemplate\.png"' "$INDEX" \
                || { echo "ERROR: patch 08b (tray icon filename) failed to apply"; exit 1; }
              echo "[patch:08b] Done"

              # --- Patch 09: DBus tray cleanup delay (regex) ---
              # Prevents StatusNotifierItem registration race on Linux
              echo "[patch:09] Patching tray DBus cleanup delay..."
              perl -i -pe 's{(\w+)&&\(\1\.destroy\(\),\1=null\)}{$1&&($1.destroy(),$1=null,setTimeout(()=>{},250))}g' "$INDEX"
              echo "[patch:09] Done"

              # --- Patch 11: shellPathWorker.js asar resolution (regex) ---
              # In wrapped-Electron builds (makeWrapper), process.resourcesPath points to the
              # Electron runtime's resources, not the Claude app.asar. Use process.argv[1]
              # (the app.asar path passed by makeWrapper) directly — Electron's fs treats
              # the asar path as a directory containing its archived files transparently.
              echo "[patch:11] Patching shellPathWorker base path..."
              perl -i -pe 's{function (\w+)\(\)\{return (\w+)\.join\(process\.resourcesPath,"app\.asar",".vite","build","shell-path-worker","shellPathWorker\.js"\)\}}{function $1(){if(process.platform==="linux"\&\&process.argv[1]\&\&process.argv[1].includes("app.asar"))return $2.join(process.argv[1],".vite","build","shell-path-worker","shellPathWorker.js");return $2.join(process.resourcesPath,"app.asar",".vite","build","shell-path-worker","shellPathWorker.js")}}g' "$INDEX"
              grep -qP 'process\.platform==="linux"&&process\.argv\[1\]&&process\.argv\[1\]\.includes\("app\.asar"\)' "$INDEX" \
                || { echo "ERROR: patch 11 (shellPathWorker base) failed to apply"; exit 1; }
              echo "[patch:11] Done"

              # --- Patch 12: Neutralize [1m] model-suffix functions (regex) ---
              # Anthropic appends "[1m]" to selected model ids; the suffixed
              # model_configs request 404s and disables Code/LOCAL sends. v1.13576.4
              # applies the suffix via TWO chained functions in the send path:
              #   WcA(A){return/\[1m\]/i.test(A)||!k().some(...)?A:`''${A}[1m]`}  (old style)
              #   czA(A,e){return!e||R.test(A)?A:`''${A}[1m]`}                     (NEW)
              # called as reconcileModel=czA(WcA(...)) and {model:czA(A,!0)}. Since
              # czA(A,!0) force-appends the suffix, BOTH must be neutralized to a
              # pass-through. The model catalog list (…map(s=>`''${s}[1m]`)) is left
              # intact, matching prior behaviour. Names vary and may contain `$`.
              echo "[patch:12] Neutralizing [1m] model-suffix functions..."
              grep -qP 'function [\w\$]+\([\w\$]+\)\{return/\\\[1m\\\]/i\.test' "$INDEX" \
                || { echo "ERROR: patch 12 target function (WcA-style) not found (pre-check)"; exit 1; }
              # 12a: WcA-style single-arg suffixer -> pass-through
              perl -i -pe 's{function ([\w\$]+)\(([\w\$]+)\)\{return/\\\[1m\\\]/i\.test\(\2\)\|\|.+?\?\2:`\$\{\2\}\[1m\]`\}}{function $1($2){return $2}}g' "$INDEX"
              # 12b: czA-style two-arg suffixer (return!e||R.test(A)?A:`''${A}[1m]`) -> pass-through
              perl -i -pe 's{function ([\w\$]+)\(([\w\$]+),([\w\$]+)\)\{return!\3\|\|[\w\$]+\.test\(\2\)\?\2:`\$\{\2\}\[1m\]`\}}{function $1($2,$3){return $2}}g' "$INDEX"
              if grep -qP 'function [\w\$]+\([\w\$,]+\)\{return[^}]{0,90}:`\$\{[\w\$]+\}\[1m\]`\}' "$INDEX"; then
                echo "ERROR: patch 12 ([1m] suffix) — a suffix function still remains"
                exit 1
              fi
              echo "[patch:12] Done"

              # --- Patch 13: RETIRED in v1.13576.4 ---
              # getHostPlatform() now ships a native Linux branch upstream:
              #   if(process.platform==="linux")return a==="arm64"?"linux-arm64":"linux-x64";
              # so it no longer throws `Unsupported platform: linux-x64`. Rather than
              # inject the branch, assert it is present — if a future version drops it,
              # this verification fails loudly so the injection can be restored.
              echo "[patch:13] Verifying native getHostPlatform Linux branch..."
              grep -qP 'getHostPlatform\(\)\{const \w+=process\.arch;.{0,160}if\(process\.platform==="linux"\)return \w+==="arm64"\?"linux-arm64":"linux-x64"' "$INDEX" \
                || { echo "ERROR: patch 13 — native getHostPlatform Linux branch missing; re-derive injection needed"; exit 1; }
              echo "[patch:13] Done (native upstream branch, no patch needed)"

              # --- Patch 14: CLAUDE_CODE_LOCAL_BINARY constructor wiring (regex) ---
              # v1.6608.2 minified the env-var bridge into a dead expression
              # (`process.env.CLAUDE_CODE_LOCAL_BINARY` standalone, no assignment).
              # Restore the v1.3883 behaviour: when the env var is set, call
              # initLocalBinary(env) and store the promise so getLocalBinaryPath()
              # short-circuits CCD entry points before they hit getHostTarget().
              # This is what makes claudeCodePackage / Code-LOCAL functional again.
              echo "[patch:14] Restoring CLAUDE_CODE_LOCAL_BINARY constructor wiring..."
              perl -i -pe 's{process\.env\.CLAUDE_CODE_LOCAL_BINARY\}async initLocalBinary}{process.env.CLAUDE_CODE_LOCAL_BINARY\&\&(this.localBinaryInitPromise=this.initLocalBinary(process.env.CLAUDE_CODE_LOCAL_BINARY))\}async initLocalBinary}g' "$INDEX"
              grep -qP 'this\.localBinaryInitPromise=this\.initLocalBinary\(process\.env\.CLAUDE_CODE_LOCAL_BINARY\)' "$INDEX" \
                || { echo "ERROR: patch 14 (CLAUDE_CODE_LOCAL_BINARY wiring) failed to apply"; exit 1; }
              echo "[patch:14] Done"

              # --- Patch 15: RETIRED in v1.13576.4 ---
              # v1.9255.x's bundle-file helper read `Qo.files[process.platform][arch]`,
              # which threw `Cannot read properties of undefined (reading 'x64')` on
              # Linux because the manifest has no "linux" key. v1.13576.4 hardcodes the
              # platform key to "darwin" (`fo.files["darwin"][arch]??[]`), so the
              # undefined-index crash can no longer occur on Linux. Assert the lookup
              # is no longer indexed by process.platform — if a dynamic-platform form
              # returns, re-derive the guard.
              echo "[patch:15] Verifying VM bundle lookup is no longer platform-dynamic..."
              grep -qP '[\w\$]+\.files\["darwin"\]\[\w+\(\)\]\?\?\[\]' "$INDEX" \
                || { echo "ERROR: patch 15 — expected darwin-keyed bundle lookup not found; re-derive guard"; exit 1; }
              if grep -qP '\.files\[\w+\]\[\w+\]\?\?\[\]' "$INDEX"; then
                echo "ERROR: patch 15 — dynamic .files[platform][arch] lookup present; re-derive guard"; exit 1
              fi
              echo "[patch:15] Done (native darwin-keyed lookup, no patch needed)"

              # --- Patch 16: Guard macOS-fork-only Electron startup APIs (regex) ---
              # Anthropic's macOS build runs a custom Electron fork with extra native
              # `app`/`systemPreferences` methods. nixpkgs' stock electron_41 lacks
              # them, so v1.13576.4's top-level app-init calls throw at module load
              # (before any window opens). Guard each so the init sequence proceeds:
              #   16a `systemPreferences.setUserDefault("NSAutoFillHeuristicsEnabled",
              #        "boolean",!1)` — macOS NSUserDefaults write. Darwin-guard it;
              #        `&&` binds tighter than the trailing comma so bCo() still runs.
              #   16b `app.configureWebAuthn({touchID:{keychainAccessGroup:…}})` (in
              #        bCo) — macOS TouchID WebAuthn config. Existence-guard it (it is
              #        an API-presence issue, not purely platform) so it no-ops on
              #        stock Electron and self-enables if a build ever ships the API.
              echo "[patch:16] Guarding macOS-fork-only Electron startup APIs..."
              perl -i -pe 's{((\w+)\.systemPreferences\.setUserDefault\("NSAutoFillHeuristicsEnabled","boolean",!1\))}{process.platform==="darwin"\&\&$1}g' "$INDEX"
              grep -qP 'process\.platform==="darwin"&&\w+\.systemPreferences\.setUserDefault\("NSAutoFillHeuristicsEnabled"' "$INDEX" \
                || { echo "ERROR: patch 16a (setUserDefault guard) failed to apply"; exit 1; }
              perl -i -pe 's{(\w+)\.app\.configureWebAuthn\(}{$1.app.configureWebAuthn\&\&$1.app.configureWebAuthn(}g' "$INDEX"
              grep -qP '\w+\.app\.configureWebAuthn&&\w+\.app\.configureWebAuthn\(' "$INDEX" \
                || { echo "ERROR: patch 16b (configureWebAuthn guard) failed to apply"; exit 1; }
              echo "[patch:16] Done"

              # --- Patch 17: Guard macOS-only BrowserWindow chrome APIs (regex) ---
              # macOS-only window-chrome methods that stock electron_41 lacks. Unlike
              # patch 16's calls these fire during window setup (async), so they don't
              # block launch — they surface as unhandled promise rejections and spam
              # Sentry. Existence-guard them:
              #   17a `win.setWindowButtonPosition({x,y})` — positions the mac traffic
              #        lights; called from a zoom-factor handler that runs on Linux.
              #   17b `win.setHiddenInMissionControl(!0)` — one call site is not behind
              #        a darwin check (always-on-top pop-up path). Blanket-guarding all
              #        sites is safe; darwin-gated ones just gain a harmless inner check.
              echo "[patch:17] Guarding macOS-only BrowserWindow chrome APIs..."
              perl -i -pe 's{(\w+)\.setWindowButtonPosition\(}{$1.setWindowButtonPosition\&\&$1.setWindowButtonPosition(}g' "$INDEX"
              grep -qP '\w+\.setWindowButtonPosition&&\w+\.setWindowButtonPosition\(' "$INDEX" \
                || { echo "ERROR: patch 17a (setWindowButtonPosition guard) failed to apply"; exit 1; }
              perl -i -pe 's{(\w+)\.setHiddenInMissionControl\(}{$1.setHiddenInMissionControl\&\&$1.setHiddenInMissionControl(}g' "$INDEX"
              grep -qP '\w+\.setHiddenInMissionControl&&\w+\.setHiddenInMissionControl\(' "$INDEX" \
                || { echo "ERROR: patch 17b (setHiddenInMissionControl guard) failed to apply"; exit 1; }
              echo "[patch:17] Done"

              # Repack ASAR
              echo "[5/6] Repacking ASAR..."
              ${asarTool}/bin/asar-tool pack extracted app.asar

              echo "=== Build complete ==="

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/claude-desktop
              cp app.asar $out/lib/claude-desktop/

              # Copy unpacked resources if they exist
              if [ -d "$(dirname $(find dmg-contents -name 'app.asar' -path '*/Contents/Resources/*' | head -1))/app.asar.unpacked" ]; then
                cp -r "$(dirname $(find dmg-contents -name 'app.asar' -path '*/Contents/Resources/*' | head -1))/app.asar.unpacked" \
                  $out/lib/claude-desktop/app.asar.unpacked
                chmod -R u+w $out/lib/claude-desktop/app.asar.unpacked
              fi

              # --- Patch 18: Linux-native node-pty pty.node ---
              # The DMG's app.asar.unpacked ships a macOS Mach-O pty.node, so node-pty
              # fails to load on Linux and the in-app terminal/shell PTY is dead. Overlay
              # the electron-41-built Linux binary (spawn-helper is macOS-only, left as-is).
              PTY_DIR="$out/lib/claude-desktop/app.asar.unpacked/node_modules/node-pty/build/Release"
              if [ -d "$PTY_DIR" ]; then
                cp ${nodePtyElectron}/pty.node "$PTY_DIR/pty.node"
                echo "[patch:18] Overlaid Linux-native node-pty pty.node"
              else
                echo "ERROR: patch 18 — node-pty unpacked dir not found at $PTY_DIR"; exit 1
              fi

              # Copy tray icons and app icon to real filesystem (alongside ASAR)
              # COSMIC's SNI can't read from inside ASAR archives, so these must
              # be on the real filesystem for the tray icon to display correctly.
              mkdir -p $out/lib/claude-desktop/resources
              for icon in extracted/resources/TrayIconTemplate*.png extracted/resources/icon.png; do
                if [ -f "$icon" ]; then
                  cp "$icon" $out/lib/claude-desktop/resources/
                fi
              done

              # Install hicolor theme icons for desktop entry
              if [ -d icon-extracted ]; then
                for png in icon-extracted/*.png; do
                  size=$(basename "$png" .png)
                  if [ "$size" -gt 0 ] 2>/dev/null; then
                    mkdir -p "$out/share/icons/hicolor/''${size}x''${size}/apps"
                    cp "$png" "$out/share/icons/hicolor/''${size}x''${size}/apps/claude.png"
                    echo "  Installed ''${size}x''${size} icon"
                  fi
                done
              fi

              runHook postInstall
            '';
          };

          # Basic Claude Desktop wrapper (direct electron) — parameterized on
          # claudeCodePackage. When non-null, wires CLAUDE_CODE_LOCAL_BINARY so
          # the Code section's LOCAL sub-mode spawns that binary instead of
          # trying to download via CCD (which throws on Linux).
          mkClaudeDesktop = claudeCodePackage: pkgs.symlinkJoin {
            name = "claude-desktop-${claudeVersion}";
            paths = [ claudeApp ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.electron_41}/bin/electron $out/bin/claude-desktop \
                --add-flags "$out/lib/claude-desktop/app.asar" \
                --add-flags "--no-sandbox" \
                --add-flags "--ozone-platform-hint=auto" \
                --add-flags "--password-store=gnome-libsecret" \
                --add-flags "--class=Claude" \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bubblewrap ]} \
                --set BWRAP_PATH "${pkgs.bubblewrap}/bin/bwrap" \
                --set CHROME_DESKTOP "claude-desktop.desktop" \
                --prefix XDG_DATA_DIRS : "$out/share" \
                ${pkgs.lib.optionalString (claudeCodePackage != null)
                  ''--set-default CLAUDE_CODE_LOCAL_BINARY "${claudeCodePackage}/bin/claude"''}

              # Desktop entry
              mkdir -p $out/share/applications
              cat > $out/share/applications/claude-desktop.desktop <<DESKTOP
              [Desktop Entry]
              Name=Claude
              Comment=Claude AI Assistant
              Exec=$out/bin/claude-desktop %U
              Icon=claude
              Type=Application
              Categories=Development;Utility;
              MimeType=x-scheme-handler/claude;
              StartupWMClass=Claude
              DESKTOP
              sed -i 's/^              //' $out/share/applications/claude-desktop.desktop
            '';
            meta = with pkgs.lib; {
              description = "Claude Desktop for Linux with Cowork support";
              homepage = "https://claude.ai";
              platforms = platforms.linux;
              mainProgram = "claude-desktop";
            };
          };

          # FHS wrapper for maximum compatibility (cowork + MCP) — parameterized
          # on claudeCodePackage, threaded through to the inner wrapper.
          mkClaudeDesktopFHS =
            claudeCodePackage:
            let
              inner = mkClaudeDesktop claudeCodePackage;
            in
            pkgs.buildFHSEnv {
            name = "claude-desktop";
            targetPkgs = pkgs: with pkgs; [
              bubblewrap
              nodejs
              python3
              glibc
              openssl
              docker-client
              coreutils
              bash
              gnugrep
              gnused
              gawk
              findutils
              git
              curl
              wget
            ];
            runScript = "${inner}/bin/claude-desktop";
            # Bind /tmp/sessions -> /sessions so Cowork VM-internal paths resolve
            extraPreBwrapCmds = ''
              mkdir -p /tmp/sessions
            '';
            extraBwrapArgs = [
              "--symlink" "/tmp/sessions" "/sessions"
            ];
            # buildFHSEnv only installs the FHS-wrapped bin; pull icons from the
            # inner so GNOME / app-launchers can resolve `Icon=claude` to a real
            # PNG. Don't propagate share/applications because the inner's
            # .desktop points at its own non-FHS bin; HM users provide their own
            # desktop entry, and standalone users run the bin directly.
            extraInstallCommands = ''
              mkdir -p $out/share
              ln -s ${inner}/share/icons $out/share/icons
            '';
            meta = with pkgs.lib; {
              description = "Claude Desktop for Linux (FHS) with Cowork and MCP support";
              homepage = "https://claude.ai";
              platforms = platforms.linux;
              mainProgram = "claude-desktop";
            };
          };

          # Default package variants: no claude-code wired in. Users enable
          # LOCAL mode via the module option `claudeCodePackage` (see below),
          # or by setting CLAUDE_CODE_LOCAL_BINARY externally.
          claudeDesktop = mkClaudeDesktop null;
          claudeDesktopFHS = mkClaudeDesktopFHS null;

        in {
          inherit
            claudeApp
            asarTool
            mkClaudeDesktop
            mkClaudeDesktopFHS
            claudeDesktop
            claudeDesktopFHS;
        };

    in {
      packages = forEachSystem (system:
        let
          b = mkBuildersFor nixpkgs.legacyPackages.${system};
        in {
          default = b.claudeDesktopFHS;
          claude-desktop = b.claudeDesktop;
          claude-desktop-fhs = b.claudeDesktopFHS;
          claude-app = b.claudeApp;
          asar-tool = b.asarTool;
        }
      );

      apps = forEachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/claude-desktop";
        };
        claude-desktop = {
          type = "app";
          program = "${self.packages.${system}.claude-desktop}/bin/claude-desktop";
        };
        claude-desktop-fhs = {
          type = "app";
          program = "${self.packages.${system}.claude-desktop-fhs}/bin/claude-desktop";
        };
      });

      # NixOS module
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.claude-desktop;
          b = mkBuildersFor pkgs;
        in {
          options.programs.claude-desktop = {
            enable = lib.mkEnableOption "Claude Desktop with Cowork support";

            package = lib.mkOption {
              type = lib.types.package;
              default = b.claudeDesktop;
              defaultText = lib.literalExpression "claude-cowork-nix.packages.\${system}.claude-desktop";
              description = "The Claude Desktop package to use.";
            };

            fhs = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Use FHS wrapper for better MCP and Cowork compatibility.";
            };

            claudeCodePackage = lib.mkOption {
              type = lib.types.nullOr lib.types.package;
              default = null;
              example = lib.literalExpression "pkgs.claude-code";
              description = ''
                Claude Code package whose `/bin/claude` will be wired as
                `CLAUDE_CODE_LOCAL_BINARY`, enabling the Code section's LOCAL
                sub-mode on Linux by short-circuiting the CCD daemon's
                `getHostPlatform` throw. When null (default), LOCAL mode
                remains unavailable unless the env var is set externally.

                Typical values:
                  pkgs.claude-code                                    # nixpkgs
                  inputs.claude-code.packages.''${system}.default       # github:sadjow/claude-code-nix
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [
              (if cfg.fhs
               then (b.mkClaudeDesktopFHS cfg.claudeCodePackage)
               else (b.mkClaudeDesktop cfg.claudeCodePackage))
              pkgs.bubblewrap
            ];
          };
        };

      # Home Manager module
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.claude-desktop;
          b = mkBuildersFor pkgs;
          pkg = if cfg.fhs
                then (b.mkClaudeDesktopFHS cfg.claudeCodePackage)
                else (b.mkClaudeDesktop cfg.claudeCodePackage);
        in {
          options.programs.claude-desktop = {
            enable = lib.mkEnableOption "Claude Desktop with Cowork support";

            package = lib.mkOption {
              type = lib.types.package;
              default = b.claudeDesktop;
              defaultText = lib.literalExpression "claude-cowork-nix.packages.\${system}.claude-desktop";
              description = "The Claude Desktop package to use.";
            };

            fhs = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Use FHS wrapper for better MCP and Cowork compatibility.";
            };

            createDesktopEntry = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Create desktop entry for Claude Desktop.";
            };

            claudeCodePackage = lib.mkOption {
              type = lib.types.nullOr lib.types.package;
              default = null;
              example = lib.literalExpression "pkgs.claude-code";
              description = ''
                Claude Code package whose `/bin/claude` will be wired as
                `CLAUDE_CODE_LOCAL_BINARY`, enabling the Code section's LOCAL
                sub-mode on Linux by short-circuiting the CCD daemon's
                `getHostPlatform` throw. When null (default), LOCAL mode
                remains unavailable unless the env var is set externally.

                Typical values:
                  pkgs.claude-code                                    # nixpkgs
                  inputs.claude-code.packages.''${system}.default       # github:sadjow/claude-code-nix
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ pkg pkgs.bubblewrap ];

            xdg.desktopEntries.claude-desktop = lib.mkIf cfg.createDesktopEntry {
              name = "Claude";
              genericName = "AI Assistant";
              exec = "${pkg}/bin/claude-desktop %U";
              icon = "claude";
              categories = [ "Development" "Utility" ];
              comment = "Claude Desktop with Linux Cowork support";
              mimeType = [ "x-scheme-handler/claude" ];
              settings = {
                StartupWMClass = "Claude";
              };
            };
          };
        };

      # Development shell
      devShells = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              nodejs
              python3
              bubblewrap
              electron_41
              dmg2img
              p7zip

              # Development tools
              prettierd
            ];

            shellHook = ''
              echo "Claude Desktop Linux Development Shell"
              echo ""
              echo "  node:     $(node --version)"
              echo "  python3:  $(python3 --version 2>&1)"
              echo "  bwrap:    $(bwrap --version 2>&1 | head -1)"
              echo "  electron: $(electron --version 2>/dev/null || echo 'available')"
              echo ""
              echo "Build:  nix build ."
              echo "Run:    nix run ."
              echo "FHS:    nix run .#claude-desktop-fhs"
            '';
          };
        }
      );
    };
}
