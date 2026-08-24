{
  description = "Claude Desktop for Linux - fully declarative NixOS package with Cowork support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Claude Desktop version and source
      claudeVersion = "1.34493.1";
      claudeDmgHash = "sha256-Ko+H9S5piLk6z3kuCt1HxKrkf6lO8d+vY7EP3vhAUM4=";
      claudeDmgUrl = "https://downloads.claude.ai/releases/darwin/universal/1.34493.1/Claude-255293a41a25d54c5177aa9614fb4cd620e70b78.dmg";

      # node-pty version bundled inside the DMG's app.asar. The Linux pty.node we
      # overlay (patch 18b) is built from this exact version — N-API keeps the ABI
      # stable across Electron versions, but not node-pty's own JS<->native API, so
      # a mismatched addon loads fine and then throws on a method the JS calls.
      # Asserted against the extracted asar at build time (patch 18a); on a version
      # bump, read node_modules/node-pty/package.json from the new DMG and update
      # this plus the tarball hash together.
      nodePtyVersion = "1.2.0-beta.14";

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
            # Must track the node-pty version whose JS the DMG bundles (see
            # node_modules/node-pty/package.json). N-API keeps the *ABI* stable across
            # Electron versions, but not node-pty's own JS<->native API: a mismatched
            # pty.node loads fine and then throws on a method the JS expects.
            version = nodePtyVersion;
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/node-pty/-/node-pty-${nodePtyVersion}.tgz";
              hash = "sha256-HACjGQuVrBY585IV15I2b9nPkSZeQaVfqxUrZTRrrvA=";
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

              # v1.20186.1 code-split the Electron main process; v1.26832.0 shattered it.
              # The load chain is now:
              #   package.json main -> .vite/build/index.pre.js  (Sentry bootstrap +
              #                                                    launch-failure dialog)
              #     -> require("./index.js")                     (242 KB, requires 159 chunks)
              #       -> index{,2}.chunk-<hash>.js               (~350 files, 14 MB total)
              #
              # Through v1.24012.9 index.js was an ~800-byte stub with a single require()
              # and that one chunk held every patch target, so "resolve the first require"
              # found it. That is no longer true on either count: index.js is itself a
              # large module holding several targets, and the rest are spread over at
              # least seven sibling chunks. Resolving "the first require" now lands on an
              # unrelated 1.7 KB chunk, which would make every regex patch fail at once.
              #
              # So don't resolve a file at all — resolve each patch's *anchor*. apply_patch
              # greps the whole build tree for the anchor, rewrites every file that has it,
              # and fails if the anchor is missing or the rewrite lands nowhere. That makes
              # the patch chain indifferent to how upstream chunks its bundle: a target
              # moving between chunks is a no-op, and only a genuine shape change fails.
              #
              # Two hazards this design accepts deliberately:
              #   - An anchor may legitimately hit files the substitution should skip (see
              #     patch 08a, whose anchor also matches the resources/i18n resolver). The
              #     substitution is the real filter; "applied in 1/2" is a pass.
              #   - A target duplicated across files must be rewritten in all of them
              #     (patches 17a/17b/19), which falls out of the loop for free.
              BUILD_DIR="extracted/.vite/build"
              MAINVIEW="$BUILD_DIR/mainView.js"

              targets_for() {
                grep -rlP --include='*.js' -- "$1" "$BUILD_DIR" 2>/dev/null | sort
              }

              # apply_patch <label> <anchor-regex> <perl-expr> <verify-regex>
              apply_patch() {
                local label="$1" anchor="$2" expr="$3" verify="$4"
                local files applied=0 seen=0 f
                files=$(targets_for "$anchor")
                if [ -z "$files" ]; then
                  echo "ERROR: patch $label — anchor matched no build file."
                  echo "  anchor: $anchor"
                  exit 1
                fi
                for f in $files; do
                  seen=$((seen + 1))
                  perl -0777 -i -pe "$expr" "$f"
                  if grep -qP -- "$verify" "$f"; then applied=$((applied + 1)); fi
                done
                if [ "$applied" -eq 0 ]; then
                  echo "ERROR: patch $label — anchor hit $seen file(s) but the rewrite applied nowhere."
                  echo "  Upstream changed the target's shape; re-derive the regex."
                  echo "  files: $(echo "$files" | tr '\n' ' ')"
                  exit 1
                fi
                echo "[patch:$label] applied in $applied/$seen file(s)"
              }

              # assert_absent_or_die <label> <regex> <message>
              assert_present() {
                grep -rqP --include='*.js' -- "$2" "$BUILD_DIR" \
                  || { echo "ERROR: patch $1 — $3"; exit 1; }
                echo "[patch:$1] verified"
              }

              echo "  Build tree: $(find "$BUILD_DIR" -name '*.js' | wc -l) JS files"

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
              # Append to index.js, the main-process entry that requires every chunk.
              # Running last in that module means all chunks are loaded before
              # global.__linuxCowork is set, which is what the availability (03) and VM
              # getter (06) patches read — they are called lazily, never at module load.
              cat ${./scripts/cowork-init.js} >> "$BUILD_DIR/index.js"
              ${pkgs.nodejs}/bin/node --check "$BUILD_DIR/index.js" \
                || { echo "ERROR: patch 01 — index.js no longer parses after append"; exit 1; }
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
              # v1.26832.0 keeps the same function body but the minifier changed twice
              # over: declarations are emitted as `let` instead of `const`, and every
              # string literal is a backtick template literal instead of double-quoted.
              # Both are global to this build, so `(?:const|let)` and `[`"]` appear in
              # every regex below — writing them as wildcards costs nothing and means a
              # future minifier flip back does not break the chain again.
              # v1.32352.0 restructured this function. It used to be
              #   f(){let a=override();if(a)return a;if(CACHE)return CACHE;
              #      let b=platformCheck();if(b.status!=="supported")…}
              # and is now
              #   f(){let a=override();if(a)return a;let b=CACHE;
              #      return b||(b=env("CLAUDE_E2E_ASSUME_VM_SUPPORTED")||…,CACHE=b,…),gate(b)}
              # so the old anchor (two consecutive early-return ifs, then a .status test)
              # no longer exists. Anchor on the CLAUDE_E2E_ASSUME_VM_SUPPORTED literal
              # instead: it is unique to this function and survives renaming, which the
              # structural prefix demonstrably does not.
              # The injection point is unchanged — first statement of the function — so
              # Linux still short-circuits ahead of the cache and the enterprise gate,
              # exactly as before.
              echo "[patch:03] Patching Cowork availability..."
              apply_patch 03 \
                'CLAUDE_E2E_ASSUME_VM_SUPPORTED' \
                's{(function ([\w\$]+)\(\)\{)((?:(?!function).)*?if\((?:(?!function).)*?[`"]CLAUDE_E2E_ASSUME_VM_SUPPORTED[`"])}{$1if(process.platform==="linux"&&global.__linuxCowork)return{status:"supported"};$3}gs' \
                'if\(process\.platform==="linux"&&global\.__linuxCowork\)return\{status:"supported"\}'
              echo "[patch:03] Done"

              # --- Patch 04: Skip download (regex) ---
              # Skips the macOS VM bundle download on Linux.
              # The old anchor was "the first `async function X(a,b){` with [downloadVM]
              # logged within 200 chars", which is no longer specific enough: v1.26832.0
              # has three such functions in the VM chunk, and the nearest one is `it(e,t)`,
              # a stale-cache *sweeper*, not the downloader. Neutralizing that would leave
              # the download running while breaking cache cleanup.
              # Anchor on the destructure instead. The exported entry point is the only
              # one shaped `async function X(a,b){let{yukonSilver:c}=…` — it reads the
              # availability verdict (which patch 03 forces to "supported" on Linux) and
              # then dispatches the real downloader. Returning !1 there is exactly the
              # branch upstream takes when the feature is unsupported.
              echo "[patch:04] Patching download skip..."
              apply_patch 04 \
                'async function [\w\$]+\([\w\$]+,[\w\$]+\)\{(?:await [\w\$.]+\(\);)*(?:const|let)\{yukonSilver:' \
                's{(async function [\w\$]+\([\w\$]+,[\w\$]+\)\{)((?:await [\w\$.]+\(\);)*(?:const|let)\{yukonSilver:[\w\$]+\}=.{0,220}?\[downloadVM\])}{$1if(process.platform==="linux"&&global.__linuxCowork){console.log("[Cowork Linux] Skipping bundle download");return!1}$2}gs' \
                'if\(process\.platform==="linux"&&global\.__linuxCowork\)\{console\.log\("\[Cowork Linux\] Skipping bundle download"\)'
              echo "[patch:04] Done"

              # --- Patch 05: VM start intercept (dynamic Node.js) ---
              # Discovers function name via [VM:start] log string, injects bubblewrap session
              # No file argument: the script locates its own target by scanning for the
              # [VM:start] anchor, the same way apply_patch does.
              echo "[patch:05] Patching VM start intercept..."
              ${pkgs.nodejs}/bin/node ${./scripts/patch-vm-start.js} extracted
              echo "[patch:05] Done"

              # --- Patch 06a: VM getter (regex) ---
              # Returns the Linux VM instance from the module's VM getters.
              # v1.26832.0 rewrote both getters with optional chaining:
              #   was: async function X(){const a=await Y();return(a==null?void 0:a.vm)??null}
              #   now: async function X(){return(await Y())?.vm??null}
              #        X.getCached=function(){return CACHED?.vm??null}
              # 06a-1 handles the async getter (as before). 06a-2 is new: the synchronous
              # `.getCached` sibling did not exist as a separate function before the
              # refactor, and callers that take the sync path would otherwise see null on
              # Linux even with a live session — a silent "Cowork not running" rather than
              # an error. Both must agree.
              echo "[patch:06a] Patching VM getter..."
              apply_patch 06a-1 \
                'async function [\w\$]+\(\)\{return\(await [\w\$]+\(\)\)\?\.vm\?\?null\}' \
                's{(async function )([\w\$]+)(\(\)\{)(return\(await [\w\$]+\(\)\)\?\.vm\?\?null\})}{$1$2$3if(process.platform==="linux"&&global.__linuxCowork&&global.__linuxCowork.vmInstance){console.log("[Cowork Linux] $2() returning Linux VM");return global.__linuxCowork.vmInstance}$4}g' \
                '\[Cowork Linux\] [\w\$]+\(\) returning Linux VM'
              apply_patch 06a-2 \
                '[\w\$]+\.getCached=function\(\)\{return [\w\$]+\?\.vm\?\?null\}' \
                's{([\w\$]+\.getCached=function\(\)\{)(return [\w\$]+\?\.vm\?\?null\})}{$1if(process.platform==="linux"&&global.__linuxCowork&&global.__linuxCowork.vmInstance)return global.__linuxCowork.vmInstance;$2}g' \
                'getCached=function\(\)\{if\(process\.platform==="linux"&&global\.__linuxCowork&&global\.__linuxCowork\.vmInstance\)return global\.__linuxCowork\.vmInstance;'
              echo "[patch:06a] Done"

              # --- Patch 06b: RETIRED (v1.26832.0) ---
              # Was: widen the platform-gated Swift-module getter (`getSwiftAddon()`,
              # exported as `.K`) so it did not short-circuit to null on Linux.
              # It cannot do anything useful now, and what it would do is harmful.
              #
              # That getter returns the raw @ant/claude-swift module, not our VM instance.
              # Its three consumers are:
              #   `let t=await K(); t&&(t.on("guestConnectionChanged",…))`
              #   `let S=await K(); … S?.on("vmStateChanged",…)`
              #   `if(await K()===null)return{xcode:!1,simulators:!1}`
              # — two call `.on()`, one tests `=== null`. So the getter is only allowed to
              # return null or a real EventEmitter. On Linux the module resolves to `{}`
              # (see patch 21), which is neither: it is truthy, so it passes the `t&&`
              # guard and survives `S?.`, then throws on `.on`.
              # Patch 21 makes the loader return null on non-darwin, so this getter now
              # yields null on Linux with or without the widening — the rewrite is
              # provably inert, and the repo's rule is that inert patches get retired
              # rather than left to rot (see patch 09).
              # Cowork does not lose anything: the VM instance the app actually drives
              # comes from the other two getters, which patches 06a-1/06a-2 intercept.
              # Restore this only if upstream ships a real Linux @ant/claude-swift that
              # is an EventEmitter — the `{}` stub is not one.
              echo "[patch:06b] Skipped (retired — getter must yield null or an EventEmitter; see patch 21)"

              # --- Patch 07: Platform branding ---
              echo "[patch:07] Injecting platform branding fix..."
              cat ${./scripts/branding-fix.js} >> "$MAINVIEW"
              echo "[patch:07] Done"

              # --- Patch 08a: Tray icon resource path (regex) ---
              # Returns real filesystem path on Linux (COSMIC SNI can't read from ASAR)
              # Two shape changes since v1.24012.9: the packaged branch reads a bare
              # `process.resourcesPath` (it used to go through a namespaced electron
              # import), and `path` is reached as `X.default.resolve` under the new
              # interop helper — hence [\w\$.]+ for module refs throughout.
              # The anchor deliberately also matches the resources/i18n resolver in a
              # different chunk; the substitution requires the argument list to END at
              # "resources", so i18n is left alone. Redirecting it would be a real bug:
              # installPhase copies only TrayIcon*/icon.png next to the asar, while the
              # i18n JSON lives inside it, and the unpatched resolver already finds it.
              echo "[patch:08a] Patching tray icon resource path..."
              apply_patch 08a \
                'function [\w\$]+\(\)\{return [\w\$]+\.app\.isPackaged\?process\.resourcesPath:[\w\$.]+\.resolve\(__dirname,' \
                's{function ([\w\$]+)\(\)\{return ([\w\$]+)\.app\.isPackaged\?process\.resourcesPath:([\w\$.]+)\.resolve\(__dirname,([`"])\.\.\4,\4\.\.\4,\4resources\4\)\}}{function $1(){return process.platform==="linux"?$3.join($3.dirname($2.app.getAppPath()),"resources"):$2.app.isPackaged?process.resourcesPath:$3.resolve(__dirname,"..","..","resources")}}g' \
                'process\.platform==="linux"\?[\w\$.]+\.join\([\w\$.]+\.dirname\('
              echo "[patch:08a] Done"

              # --- Patch 08b: Tray icon filename (regex) ---
              # The tray icon is chosen by a switch on a build-time icon-type const
              # (`Ymt="template-image"` in the macOS build we repackage):
              #   switch(Ymt){case"ico":  t=dark?"Tray-Win32-Dark.ico":"Tray-Win32.ico";break;
              #               case"template-image": t="TrayIconTemplate.png";break;
              #               case"png": t=de()==="gnome"||dark?"TrayIconLinux-Dark.png"
              #                                                :"TrayIconLinux.png";break}
              # v1.20186.1 added that "png" case with real Linux tray assets (shipped in
              # the DMG) and a GNOME check — GNOME's top bar is dark, so it forces the
              # dark icon regardless of theme. But the const is baked to "template-image",
              # so on Linux we always land on the macOS template: a non-theme-aware PNG
              # that COSMIC's SNI cannot invert the way macOS does.
              # Route the template case to upstream's own Linux expression on Linux,
              # capturing the desktop-env fn and electron namespace from the "png" case
              # so their minified names stay wildcards. Non-Linux behaviour is unchanged.
              # The desktop-environment probe is now reached through a namespace
              # (`p.rt()` rather than a local `de()`), so the captured callee must allow
              # dots. Quote style is captured (\1) and reused.
              echo "[patch:08b] Patching tray icon filename selection..."
              # v1.32352.0 turned the switch from assign-then-break into direct
              # returns, and gave the "png" case an extra leading term (a force-dark
              # flag the caller passes when retrying after a tray crash). Rather than
              # re-spell that condition, capture it whole ([^;]+? — it contains no
              # semicolon) and reuse it, so upstream can keep changing what feeds the
              # dark/light choice without breaking us.
              apply_patch 08b \
                'case[`"]template-image[`"]:return[`"]TrayIconTemplate\.png[`"];' \
                's{case([`"])template-image\1:return\1TrayIconTemplate\.png\1;(case\1png\1:return ([^;]+?)\?\1TrayIconLinux-Dark\.png\1:\1TrayIconLinux\.png\1)}{case$1template-image$1:return process.platform==="linux"?($3?"TrayIconLinux-Dark.png":"TrayIconLinux.png"):"TrayIconTemplate.png";$2}g' \
                'case[`"]template-image[`"]:return process\.platform==="linux"\?\('
              echo "[patch:08b] Done"

              # --- Patch 09: RETIRED (v1.26832.0) ---
              # Was: rewrite `X&&(X.destroy(),X=null)` to append `setTimeout(()=>{},250)`,
              # described as a DBus tray cleanup delay.
              # Retired for two independent reasons, either of which is sufficient:
              #   1. The shape is gone. v1.26832.0 guards the teardown with an
              #      isDestroyed() check and drops the parenthesised group:
              #        `$&&!$.isDestroyed()&&$.destroy(),$=null,Gf=null,i.w();`
              #      The old regex matches nothing anywhere in the tree.
              #   2. The payload never did anything. Scheduling an empty callback does
              #      not delay the surrounding synchronous statement — it just queues a
              #      timer nobody awaits. Tray destroy/recreate ordering is unchanged
              #      with or without it.
              # This patch had no verification grep, so (1) would have silently no-opped
              # exactly like the ASAR-header bug in patch 18 did. Every patch below now
              # goes through apply_patch, which fails the build instead. If an SNI
              # re-registration race does show up, fix it by deferring the *recreate*,
              # not by queueing a timer next to the destroy.
              echo "[patch:09] Skipped (retired — pattern gone upstream, payload was inert)"

              # --- Patch 11: shellPathWorker.js asar resolution (regex) ---
              # In wrapped-Electron builds (makeWrapper), process.resourcesPath points to the
              # Electron runtime's resources, not the Claude app.asar. Use process.argv[1]
              # (the app.asar path passed by makeWrapper) directly — Electron's fs treats
              # the asar path as a directory containing its archived files transparently.
              echo "[patch:11] Patching shellPathWorker base path..."
              apply_patch 11 \
                'function [\w\$]+\(\)\{return [\w\$.]+\.join\(process\.resourcesPath,[`"]app\.asar[`"]' \
                's{function ([\w\$]+)\(\)\{return ([\w\$.]+)\.join\(process\.resourcesPath,([`"])app\.asar\3,\3\.vite\3,\3build\3,\3shell-path-worker\3,\3shellPathWorker\.js\3\)\}}{function $1(){if(process.platform==="linux"&&process.argv[1]&&process.argv[1].includes("app.asar"))return $2.join(process.argv[1],".vite","build","shell-path-worker","shellPathWorker.js");return $2.join(process.resourcesPath,"app.asar",".vite","build","shell-path-worker","shellPathWorker.js")}}g' \
                'process\.platform==="linux"&&process\.argv\[1\]&&process\.argv\[1\]\.includes\("app\.asar"\)'
              echo "[patch:11] Done"

              # --- Patch 12: RETIRED in v1.20186.1 ---
              # Up to v1.13576.4 the send path force-appended "[1m]" to the selected
              # model id via two chained suffixer functions:
              #   WcA(A){return/\[1m\]/i.test(A)||!k().some(...)?A:`''${A}[1m]`}
              #   czA(A,e){return!e||R.test(A)?A:`''${A}[1m]`}
              # The suffixed id 404s against model_configs, which disabled the Code/LOCAL
              # send button — so both were neutralized to pass-throughs.
              # v1.20186.1 removes the forced suffixing entirely. "[1m]" now survives only
              # in the model *catalog* builders, which expand a 1M-capable model into two
              # selectable entries ([id, id[1m]] with supports_1m_context:!0) — opt-in, and
              # exactly what this patch always left intact. Nothing to neutralize.
              # Assert no forced suffixer returns; if one does, the send button silently
              # breaks again, so fail loudly and restore the pass-through rewrite.
              # Regex note: the brace after the dollar is written as a character class,
              # so a dollar-brace pair never appears literally here. Nix reads that pair
              # as string interpolation even inside a shell comment, so keeping it out of
              # the file entirely is the only reliable way to avoid escaping ambiguity.
              echo "[patch:12] Verifying no forced [1m] model-suffix function remains..."
              if grep -rqP --include='*.js' -- '\?[\w\$]+:[`"]\$[{][\w\$]+[}]\[1m\][`"]' "$BUILD_DIR"; then
                echo "ERROR: patch 12 — a forced [1m] suffix function is back; restore the neutralizing rewrite"
                exit 1
              fi
              echo "[patch:12] Done (upstream no longer force-appends [1m], no patch needed)"

              # --- Patch 13: RETIRED in v1.13576.4 ---
              # getHostPlatform() now ships a native Linux branch upstream:
              #   if(process.platform==="linux")return a==="arm64"?"linux-arm64":"linux-x64";
              # so it no longer throws `Unsupported platform: linux-x64`. Rather than
              # inject the branch, assert it is present — if a future version drops it,
              # this verification fails loudly so the injection can be restored.
              echo "[patch:13] Verifying native getHostPlatform Linux branch..."
              assert_present 13 \
                'getHostPlatform\(\)\{(?:const|let) [\w\$]+=process\.arch;.{0,220}if\(process\.platform===([`"])linux\1\)return [\w\$]+===\1arm64\1\?\1linux-arm64\1:\1linux-x64\1' \
                'native getHostPlatform Linux branch missing; re-derive injection needed'
              echo "[patch:13] Done (native upstream branch, no patch needed)"

              # --- Patch 14: CLAUDE_CODE_LOCAL_BINARY constructor wiring (regex) ---
              # v1.6608.2 minified the env-var bridge into a dead expression
              # (`process.env.CLAUDE_CODE_LOCAL_BINARY` standalone, no assignment).
              # Restore the v1.3883 behaviour: when the env var is set, call
              # initLocalBinary(env) and store the promise so getLocalBinaryPath()
              # short-circuits CCD entry points before they hit getHostTarget().
              # This is what makes claudeCodePackage / Code-LOCAL functional again.
              # The only patch whose target text is byte-identical to v1.24012.9 — it
              # matches no string literals, so the minifier's quote flip did not touch it.
              echo "[patch:14] Restoring CLAUDE_CODE_LOCAL_BINARY constructor wiring..."
              apply_patch 14 \
                'process\.env\.CLAUDE_CODE_LOCAL_BINARY\}async initLocalBinary' \
                's{process\.env\.CLAUDE_CODE_LOCAL_BINARY\}async initLocalBinary}{process.env.CLAUDE_CODE_LOCAL_BINARY&&(this.localBinaryInitPromise=this.initLocalBinary(process.env.CLAUDE_CODE_LOCAL_BINARY))\}async initLocalBinary}g' \
                'this\.localBinaryInitPromise=this\.initLocalBinary\(process\.env\.CLAUDE_CODE_LOCAL_BINARY\)'
              echo "[patch:14] Done"

              # --- Patch 15: RETIRED (v1.13576.4), re-verified for v1.20186.1 ---
              # v1.9255.x's bundle-file helper read `Qo.files[process.platform][arch]`,
              # which threw `Cannot read properties of undefined (reading 'x64')` on
              # Linux because the manifest had no "linux" key. v1.13576.4 dodged that by
              # hardcoding the key to "darwin".
              # v1.20186.1 goes further and makes Linux a real platform key: a mapper
              # folds both desktop unices into one bucket
              #   G4(p){switch(p){case"darwin":case"linux":return"unix";
              #                   case"win32":return"win32";default:return null}}
              # and the manifest ships `files.unix.{x64,arm64}` (a rootfs.img), so the
              # lookup `ur.files[G4(process.platform)][arch]??[]` resolves on Linux and
              # the undefined-index crash is structurally impossible. (Upstream also
              # added a downloads.claude.ai/vms/linux/<arch>/<sha> URL builder — see
              # COWORK_PROGRESS.md; we still skip the download via patch 04.)
              # Losing the linux->unix mapping is what would resurrect the crash, so
              # assert it, plus the null-guard that keeps an unknown platform from
              # indexing undefined.
              echo "[patch:15] Verifying VM bundle lookup maps Linux to a real key..."
              assert_present 15 \
                'switch\([\w\$]+\)\{case([`"])darwin\1:case\1linux\1:return\1unix\1;' \
                'linux is no longer mapped to a bundle key; re-derive guard'
              assert_present 15 \
                'if\(![\w\$]+\)return\[\];(?:const|let) [\w\$]+=[\w\$]+\(\);return [\w\$.]+\.files\[[\w\$]+\]\[[\w\$]+\]\?\?\[\]' \
                'bundle lookup lost its null-platform guard; re-derive guard'
              echo "[patch:15] Done (linux maps to files.unix upstream, no patch needed)"

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
              # 16a and 16b now live in different chunks (index.js and a lazily-required
              # WebAuthn chunk respectively), which is exactly the scatter apply_patch
              # exists to absorb — neither needs a hardcoded filename.
              echo "[patch:16] Guarding macOS-fork-only Electron startup APIs..."
              apply_patch 16a \
                '[\w\$]+\.systemPreferences\.setUserDefault\([`"]NSAutoFillHeuristicsEnabled[`"]' \
                's{(([\w\$]+)\.systemPreferences\.setUserDefault\(([`"])NSAutoFillHeuristicsEnabled\3,\3boolean\3,!1\))}{process.platform==="darwin"&&$1}g' \
                'process\.platform==="darwin"&&[\w\$]+\.systemPreferences\.setUserDefault\([`"]NSAutoFillHeuristicsEnabled'
              apply_patch 16b \
                '[\w\$]+\.app\.configureWebAuthn\(' \
                's{([\w\$]+)\.app\.configureWebAuthn\(}{$1.app.configureWebAuthn&&$1.app.configureWebAuthn(}g' \
                '[\w\$]+\.app\.configureWebAuthn&&[\w\$]+\.app\.configureWebAuthn\('
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
              # Both APIs are called from two chunks each in v1.26832.0 (index.js plus a
              # sibling), and every site must be guarded — one unguarded call is one
              # unhandled rejection. apply_patch rewrites all files holding the anchor,
              # so "applied in 2/2" is the expected line here, not 1/2.
              echo "[patch:17] Guarding macOS-only BrowserWindow chrome APIs..."
              apply_patch 17a \
                '[\w\$]+\.setWindowButtonPosition\(' \
                's{([\w\$]+)\.setWindowButtonPosition\(}{$1.setWindowButtonPosition&&$1.setWindowButtonPosition(}g' \
                '[\w\$]+\.setWindowButtonPosition&&[\w\$]+\.setWindowButtonPosition\('
              apply_patch 17b \
                '[\w\$]+\.setHiddenInMissionControl\(' \
                's{([\w\$]+)\.setHiddenInMissionControl\(}{$1.setHiddenInMissionControl&&$1.setHiddenInMissionControl(}g' \
                '[\w\$]+\.setHiddenInMissionControl&&[\w\$]+\.setHiddenInMissionControl\('
              echo "[patch:17] Done"

              # --- Patch 18a: reserve node-pty's build/Release in the ASAR header ---
              # node-pty resolves its addon by trying, in order, build/Release,
              # build/Debug, then prebuilds/<platform>-<arch> (lib/utils.js:loadNativeModule),
              # relative to both the package root and lib/. The macOS DMG ships its addon
              # under prebuilds/darwin-{x64,arm64}/ (node-pty switched to a prebuildify
              # layout in 1.2.x), so there is no build/Release for us to overlay and no
              # linux-* prebuild directory at all.
              # asar_tool skips unpacked files on extract but keeps their directories, so
              # the header records those dirs. Reserve build/Release the same way, then
              # drop the Linux pty.node into the matching app.asar.unpacked path in
              # installPhase (patch 18b). build/Release is first in the search order and
              # is arch-agnostic, so it wins over the darwin prebuilds without needing a
              # linux-x64/linux-arm64 split.
              # The overlaid pty.node (patch 18b) is compiled from nodePtyVersion. N-API
              # keeps the *ABI* stable, but node-pty's own JS<->native contract changes
              # between releases, so a drifted pair loads without error and then throws
              # on the first method the bundled JS calls that the addon doesn't export —
              # a runtime-only failure no regex verification would catch. Assert the
              # DMG's bundled JS matches what we built against.
              echo "[patch:18a] Reserving node-pty build/Release in ASAR header..."
              BUNDLED_PTY=$(${pkgs.nodejs}/bin/node -e 'process.stdout.write(require("./extracted/node_modules/node-pty/package.json").version)')
              if [ "$BUNDLED_PTY" != "${nodePtyVersion}" ]; then
                echo "ERROR: patch 18a — node-pty version drift."
                echo "  DMG bundles: $BUNDLED_PTY"
                echo "  flake builds: ${nodePtyVersion}"
                echo "  Update nodePtyVersion (and the tarball hash) in flake.nix to match the DMG."
                exit 1
              fi
              echo "[patch:18a] node-pty $BUNDLED_PTY matches the addon we build"
              # Stage the addon so the packer can emit a real header entry for it.
              # An empty build/Release directory is NOT enough: Electron only
              # redirects a read into app.asar.unpacked when the header contains the
              # *file* entry with "unpacked":true. Without it the require fails ENOENT
              # even though the binary is sitting on disk — which is exactly how the
              # in-app terminal broke silently (header showed `"Release":{}`).
              mkdir -p extracted/node_modules/node-pty/build/Release
              cp ${nodePtyElectron}/pty.node extracted/node_modules/node-pty/build/Release/pty.node
              echo "[patch:18a] Done"

              # --- Patch 19: Bypass the macOS "disclaimer" spawn helper (regex) ---
              # v1.24012.9 routes *every* spawnAsync through a macOS-only helper binary:
              #   function getDisclaimerBinaryPath(){{const c=path.dirname(process.resourcesPath);
              #                                       return path.join(c,"Helpers","disclaimer")}}
              #   function getUntrustedLaunchOptions(o){const d=getDisclaimerBinaryPath();
              #                                         return{cmd:d,args:[o.cmd,...o.args]}}
              # On macOS that helper calls responsibility_spawnattrs_setdisclaim() so the
              # child isn't attributed to Claude for TCC prompts. It ships only inside the
              # .app bundle's Contents/Helpers, so on Linux every spawn resolves to a
              # nonexistent path and fails ENOENT. The visible damage is login-shell
              # environment extraction: it retries 5x and then falls back to the bare
              # process.env, so the user's PATH and exported vars (direnv, nvm, anything
              # from .zshrc) never reach Claude Code, MCP servers, or the terminal.
              # Note the vestigial bare `{...}` block in getDisclaimerBinaryPath — that is
              # a dead-code-eliminated `if(process.platform==="darwin")`, i.e. the guard
              # existed upstream and was optimized away in the macOS build. Restore it at
              # the wrapper instead: return the command unwrapped on non-darwin, which is
              # exactly what upstream does where the helper is unavailable.
              # `er()`/spawnAsync compares `rewritten.cmd !== originalCmd` to decide whether
              # to tag errors "via disclaimer"; the pass-through keeps them equal, so spawn
              # failures surface with their own message rather than a bogus disclaimer one.
              # The wrapper is duplicated in two textual shapes — minified single-line in a
              # chunk, pretty-printed multi-line in a worker bundle — so match in slurp
              # mode with flexible whitespace, and require the same parameter name on both
              # `.cmd` and `.args` so only the real wrapper matches. That parameter check
              # is load-bearing: a Windows PowerShell helper elsewhere in the tree also
              # returns `{cmd:…,args:[…]}` and must not be rewritten.
              # The site list was hardcoded to three files; v1.26832.0 has two. The
              # shellPathWorker copy is gone (that worker no longer spawns through the
              # helper), and hardcoding meant a missing file was a hard error — a build
              # break for something upstream is free to do. Discover the sites from the
              # "Helpers"/"disclaimer" path join, which sits in the same bundle as every
              # wrapper it feeds.
              echo "[patch:19] Bypassing macOS disclaimer spawn helper..."
              # v1.34493.1 changed the fix, and for the better. Earlier releases had a
              # wrapper with no non-darwin escape at all, so the patch had to rewrite the
              # wrapper's own return shape — and that shape moved every release (v1.32352.0
              # added process groups and a third return key, killing the previous regex).
              # Upstream now ships its own no-helper fallback:
              #   function resolve(){{let d=dirname(process.resourcesPath);
              #                       return join(d,`Helpers`,`disclaimer`)}}
              #   function get(){return resolve()}
              #   function wrap(o){let t=get();
              #     if(!t)return{cmd:o.cmd,args:o.args,processGroupLeader:!1};
              #     let g=o.processGroup===!0;
              #     return{cmd:t,args:[...g?[`--pgroup`]:[],`--`,o.cmd,...o.args],
              #            processGroupLeader:g}}
              # so making the *resolver* return null on non-darwin routes the caller onto
              # upstream's own pass-through — the same "fix at the loader, not the call
              # site" principle patches 20 and 21 follow. Three things this buys us:
              #   - The pass-through already sets processGroupLeader:!1, so we no longer
              #     hand-write that invariant (see below for why it must be false).
              #   - It also covers the second wrapper, the `--ports-only` variant, which
              #     reads the same resolver and returns its argument unchanged on null.
              #     The old call-site patch never touched it.
              #   - No parameter backreference is needed any more. The old regex carried
              #     one to stop a Windows PowerShell helper elsewhere in the tree (which
              #     also returns {cmd,args}) from being rewritten; anchoring on the
              #     Helpers/disclaimer path join is inherently unique to this resolver.
              # Note the injection lands inside the vestigial bare `{...}` block — the
              # fossil of a dead-code-eliminated `if(process.platform==="darwin")`. A
              # return inside a bare block still returns from the function.
              #
              # Why processGroupLeader must be false on Linux: it selects the transport
              # class. The process-group transport arms a reaper that calls
              # process.kill(-pid), which only works if the child really is a group leader
              # — and on macOS it is one only because the disclaimer helper was invoked
              # with --pgroup. With the helper bypassed nothing creates the group, so
              # claiming true would give a reaper whose kills silently fail.
              # Trade-off, and it is upstream's to give us: MCP server subtrees are not
              # group-reaped on Linux. That capability is implemented inside a macOS-only
              # binary, so it has never worked here. The recursive `pgrep -P` tree killer
              # partially compensates — which is why procps must stay in the FHS env.
              #
              # Both copies are minified in this release, but the shapes have alternated
              # before (fileIndexWorker.js was pretty-printed through v1.26832.0), so the
              # regex stays whitespace-flexible and runs in -0777 slurp mode. Site count
              # is discovered from the anchor, never hardcoded: it was 3 through
              # v1.24012.9, 2 since. Both sites must apply — one unguarded resolver is
              # every spawn in that process ENOENTing.
              apply_patch 19 \
                '[`"]Helpers[`"]\s*,\s*[`"]disclaimer[`"]' \
                's{(function\s+[\w\$]+\s*\(\s*\)\s*\{\s*\{\s*)((?:const|let)\s+[\w\$]+\s*=\s*[\w\$.]+\.dirname\(process\.resourcesPath\)\s*;\s*return\s+[\w\$.]+\.join\([\w\$]+\s*,\s*[`"]Helpers[`"]\s*,\s*[`"]disclaimer[`"]\))}{$1if(process.platform!=="darwin")return null;$2}gs' \
                'if\(process\.platform!=="darwin"\)return null;\s*(?:const|let)\s+[\w\$]+\s*=\s*[\w\$.]+\.dirname\(process\.resourcesPath\)'
              echo "[patch:19] Done"

              # --- Patch 20: Swift notification backend must not engage on Linux (regex) ---
              # New in v1.26832.0. NotificationService.initialize() picks its backend by
              # truthiness of the Swift addon:
              #   let m=await loadSwift();
              #   m ? (this.useSwiftNotifications=!0, this.setupSwiftNotificationHandlers(m), …)
              #     : log("initialized with Electron notifications")
              # and the handler setup ends in `m.on("notificationInteraction", …)`.
              # The catch is in @ant/claude-swift's own non-darwin fallback:
              #   if (process.platform === "darwin") module.exports = new SwiftAddon();
              #   else                               module.exports = {};
              # `{}` is truthy, so on Linux the import *succeeds*, the Swift branch is
              # taken, and `.on` is undefined — an unhandled rejection during startup:
              #   TypeError: e.on is not a function
              #       at Object.setupSwiftNotificationHandlers
              # plus a Sentry event, on every launch. The window still opens (this is the
              # "clean launch is not a working app" case), but the service is left with
              # useSwiftNotifications=true and no working backend, so desktop
              # notifications never reach the Electron path that does work on Linux.
              # Fix at the loader, not the call site: returning null is precisely what the
              # existing catch block does when the module is unavailable, and it is what
              # makes initialize() log "initialized with Electron notifications" and wire
              # up the backend that Linux actually has.
              # `@` is escaped because perl interpolates arrays into s/// patterns.
              # Other @ant/claude-swift consumers were checked and need no equivalent
              # guard: the updater and quick-access loaders are already darwin-gated, the
              # permission fixer tests `!m?.permissionFixer` and throws cleanly, watch-record
              # is behind a darwin-only availability gate, and the VM loader's consumers
              # are already intercepted by patches 06a/06b.
              echo "[patch:20] Disabling Swift notification backend on Linux..."
              apply_patch 20 \
                'async function [\w\$]+\(\)\{try\{return [\w\$]+=\(await import\([`"]@ant/claude-swift[`"]\)\)\.default,' \
                's{(async function [\w\$]+\(\)\{)(try\{return [\w\$]+=\(await import\([`"]\@ant/claude-swift[`"]\)\)\.default,)}{$1if(process.platform!=="darwin")return null;$2}g' \
                'if\(process\.platform!=="darwin"\)return null;try\{return [\w\$]+=\(await import\('
              echo "[patch:20] Done"

              # --- Patch 21: Swift VM module loader must not engage on Linux (regex) ---
              # Same root cause as patch 20, different subsystem. The VM module loader is:
              #   async function loadVM(){return CACHED||PENDING||(log("[VM] Loading %s module…"),
              #     PENDING=(async()=>{try{{let m=(await import("@ant/claude-swift")).default;
              #                             m.vm=wrapProxy(m.vm),CACHED=m}
              #                          return log("[VM] Module loaded successfully"),CACHED}
              #                        catch(e){return logError("[VM] Failed to load module: %o",e),
              #                                        captureException(e),null}})(),PENDING)}
              # On Linux the import succeeds with `{}`, so `m.vm` is undefined and the
              # wrapper does `new Proxy(undefined,…)`:
              #   [VM] Failed to load module: TypeError: Cannot create proxy with a
              #   non-object as target or handler
              # It is caught and null is returned — the right value — but only after
              # throwing and firing captureException, so every Linux launch ships a Sentry
              # event for a condition that is simply "not macOS".
              # Note the bare `{…}` block wrapping the import inside the try: another
              # dead-code-eliminated `if(process.platform==="darwin")`, the same fossil
              # patch 19 found in getDisclaimerBinaryPath. Upstream guarded this and the
              # macOS build optimized the guard away; restoring it returns the identical
              # value by the intended path instead of via an exception.
              # Cowork is unaffected: its VM instance comes from global.__linuxCowork via
              # patches 05 and 06a, never from this module.
              echo "[patch:21] Disabling Swift VM module loader on Linux..."
              apply_patch 21 \
                'async function [\w\$]+\(\)\{return [\w\$]+\|\|[\w\$]+\|\|\([\w\$.]+\.info\([`"]\[VM\] Loading' \
                's{(async function [\w\$]+\(\)\{)(return [\w\$]+\|\|[\w\$]+\|\|\([\w\$.]+\.info\([`"]\[VM\] Loading)}{$1if(process.platform!=="darwin")return null;$2}g' \
                'if\(process\.platform!=="darwin"\)return null;return [\w\$]+\|\|'
              echo "[patch:21] Done"

              # --- Patch 22: Linux single-instance + claude:// deep-link delivery ---
              # Fixes #52 and #57. Ported from PR #53 (thanks @stuckj); renumbered from
              # that PR's "20" because 20 and 21 were taken in the meantime, and
              # re-anchored because the flake moved from a single $INDEX to anchor-based
              # discovery.
              #
              # v1.24012.9 dropped the non-darwin arm of the main process's deep-link
              # setup. Through v1.9255.2 it branched on platform:
              #   isMac ? (app.on("open-url", ...), app.on("continue-activity", ...))
              #         : app.requestSingleInstanceLock()
              #             ? app.on("second-instance", (e,argv)=>{focus();dispatch(argv)})
              #             : app.quit();
              # Since then it registers open-url, will-continue-activity and
              # continue-activity unconditionally — and all three are macOS-only Electron
              # events. requestSingleInstanceLock and second-instance are absent from the
              # entire tree, and there is no cold-start argv scan for the scheme.
              #
              # On Linux that means every `claude-desktop claude://...` (i.e. every
              # xdg-open of the scheme handler) starts a second full app against one
              # --user-data-dir, and the URL sits unread in its argv. Since the in-process
              # auth path (ASWebAuthenticationSession) is macOS-only, OAuth sign-in cannot
              # complete at all: the callback never gets back in, so the "sign in again"
              # banner is permanent and every attempt opens another window.
              #
              # Appended rather than substituted because there is no surviving call site
              # to rewrite — the arm is gone, not renamed. Appended to index.js for the
              # same reason patch 01 is: it is the entry that requires every chunk, so the
              # append runs after the app has registered its own "open-url" listener but
              # before "ready" — the only window in which requestSingleInstanceLock() is
              # still useful. The script re-emits that listener rather than reimplementing
              # dispatch (the app already owns mainView readiness, the pending-URL stash
              # and window focus), so the only structural assumption is that the listener
              # exists — which is what the first assertion pins.
              #
              # The listener grep must accept a backtick: this build minifies every string
              # literal to a template literal, so it is app.on(`open-url`, not
              # app.on("open-url"). PR #53's double-quote-only assertion would fail here.
              #
              # The second assertion is the drop-this-patch tripwire: if upstream restores
              # the non-darwin arm itself, the build fails loudly rather than installing
              # two competing single-instance handlers.
              echo "[patch:22] Restoring Linux deep-link handling..."
              if [ -z "$(targets_for 'app\.on\(\s*[`"]open-url[`"]')" ]; then
                echo "ERROR: patch 22 — no app.on(\`open-url\`) listener anywhere in the build tree;"
                echo "  the dispatch this patch re-emits into is gone. Re-derive before shipping."
                exit 1
              fi
              if [ -n "$(targets_for 'requestSingleInstanceLock')" ]; then
                echo "ERROR: patch 22 — the app requests a single-instance lock again."
                echo "  Upstream likely restored the non-darwin arm; drop this patch rather"
                echo "  than installing a second competing handler."
                exit 1
              fi
              cat ${./scripts/linux-deep-link.js} >> "$BUILD_DIR/index.js"
              grep -qP 'requestSingleInstanceLock' "$BUILD_DIR/index.js" \
                || { echo "ERROR: patch 22 (deep-link handling) failed to apply"; exit 1; }
              ${pkgs.nodejs}/bin/node --check "$BUILD_DIR/index.js" \
                || { echo "ERROR: patch 22 — index.js no longer parses after append"; exit 1; }
              echo "[patch:22] Done"

              # --- Post-patch syntax sweep ---
              # Every rewrite above is a regex against minified JavaScript, where a
              # mis-balanced brace produces a file that still greps clean and only fails
              # when Electron requires it — i.e. at runtime, in a subsystem that may well
              # catch, log and degrade rather than crash. Patch 19 already parsed its own
              # targets; do it for the whole tree, since apply_patch can now write to any
              # file. 357 files, a few seconds, and it converts a class of silent runtime
              # breakage into a build failure.
              echo "[5/6] Verifying all build files still parse..."
              PARSE_FAILS=0
              for f in $(find "$BUILD_DIR" -name '*.js'); do
                ${pkgs.nodejs}/bin/node --check "$f" 2>/dev/null || {
                  echo "  PARSE FAILURE: $f"; PARSE_FAILS=$((PARSE_FAILS + 1));
                }
              done
              if [ "$PARSE_FAILS" -ne 0 ]; then
                echo "ERROR: $PARSE_FAILS build file(s) no longer parse after patching"; exit 1
              fi
              echo "  All build files parse"

              # Repack ASAR. node-pty's addon is recorded as an unpacked entry rather
              # than stored inline — native modules must live on the real filesystem,
              # and the header entry is what makes Electron look for it in
              # app.asar.unpacked (patch 18a/18b). asar-tool hard-fails if the path is
              # missing, so a node-pty layout change can't silently drop the entry.
              echo "[6/6] Repacking ASAR..."
              ${asarTool}/bin/asar-tool pack extracted app.asar \
                --unpacked node_modules/node-pty/build/Release/pty.node

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

              # --- Patch 18b: Linux-native node-pty pty.node ---
              # The DMG only ships macOS Mach-O addons (prebuilds/darwin-{x64,arm64}/
              # pty.node), so node-pty finds nothing loadable on Linux and the in-app
              # terminal/shell PTY is dead ("Cannot find module .../pty.node"). Install the
              # electron-41-built Linux binary into build/Release, the first path node-pty
              # searches; patch 18a reserved the matching dir in the ASAR header.
              # The darwin prebuilds are left in place (inert on Linux), as is spawn-helper
              # — pty.cc only execs it under __APPLE__; Linux forks directly.
              PTY_UNPACKED="$out/lib/claude-desktop/app.asar.unpacked/node_modules/node-pty"
              if [ ! -d "$PTY_UNPACKED" ]; then
                echo "ERROR: patch 18b — node-pty unpacked dir not found at $PTY_UNPACKED"; exit 1
              fi
              mkdir -p "$PTY_UNPACKED/build/Release"
              cp ${nodePtyElectron}/pty.node "$PTY_UNPACKED/build/Release/pty.node"
              # A Mach-O binary here would load-fail at runtime rather than at build time,
              # so confirm we actually staged an ELF.
              case "$(head -c4 "$PTY_UNPACKED/build/Release/pty.node" | od -An -tx1 | tr -d ' \n')" in
                7f454c46) echo "[patch:18b] Overlaid Linux-native node-pty pty.node (ELF)" ;;
                *) echo "ERROR: patch 18b — staged pty.node is not an ELF binary"; exit 1 ;;
              esac

              # An ELF on disk is necessary but not sufficient: Electron reaches it only
              # via a header entry marked "unpacked". Without that entry node-pty reports
              # `Cannot find module './prebuilds/linux-x64/pty.node'` at runtime after
              # silently failing build/Release — no build-time symptom whatsoever.
              # Assert the entry exists and its recorded size matches the installed file.
              ${pkgs.python3}/bin/python3 - "$out/lib/claude-desktop/app.asar" "$PTY_UNPACKED/build/Release/pty.node" <<'PYCHECK'
              import json, os, struct, sys
              asar, real = sys.argv[1], sys.argv[2]
              with open(asar, 'rb') as f:
                  header_size = struct.unpack('<I', f.read(16)[12:16])[0]
                  meta = json.loads(f.read(header_size).rstrip(b'\0').decode('utf-8'))
              node = meta
              for part in ['node_modules', 'node-pty', 'build', 'Release', 'pty.node']:
                  node = node.get('files', {}).get(part)
                  if node is None:
                      sys.exit(f"ERROR: patch 18b — ASAR header has no entry for {part} "
                               "in node_modules/node-pty/build/Release/pty.node")
              if not node.get('unpacked'):
                  sys.exit("ERROR: patch 18b — pty.node header entry is not marked unpacked; "
                           "Electron will not redirect to app.asar.unpacked")
              actual = os.path.getsize(real)
              if node.get('size') != actual:
                  sys.exit(f"ERROR: patch 18b — header size {node.get('size')} != installed size {actual}")
              print(f"[patch:18b] ASAR header records pty.node as unpacked ({actual} bytes)")
              PYCHECK

              # Copy tray icons and app icon to real filesystem (alongside ASAR)
              # COSMIC's SNI can't read from inside ASAR archives, so these must
              # be on the real filesystem for the tray icon to display correctly
              # (patch 08a points the resource path here on Linux).
              # Glob every TrayIcon* family, not just TrayIconTemplate*: patch 08b selects
              # the TrayIconLinux{,-Dark}.png assets that v1.20186.1 added, and a tray image
              # that is merely missing renders as a blank icon with no error — so assert
              # the files 08b names are actually present.
              mkdir -p $out/lib/claude-desktop/resources
              for icon in extracted/resources/TrayIcon*.png extracted/resources/icon.png; do
                if [ -f "$icon" ]; then
                  cp "$icon" $out/lib/claude-desktop/resources/
                fi
              done
              for required in TrayIconLinux.png TrayIconLinux-Dark.png; do
                if [ ! -f "$out/lib/claude-desktop/resources/$required" ]; then
                  echo "ERROR: tray icon $required missing — patch 08b selects it on Linux"; exit 1
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
              # procps supplies `ps`, which the app shells out to for two things:
              # per-child memory enumeration (without it the process-memory sampler
              # logs children=unavailable(ps-failed) forever) and, more importantly,
              # `ps -o pgid= -o tpgid= -p <pid>` to decide whether a bash PTY has a
              # foreground job running. That second one is a real feature, not
              # telemetry, and it silently reported "no busy shells" without this.
              procps
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
