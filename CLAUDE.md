# claude-cowork-nix

Enabling macOS-only Claude Desktop features on Linux via runtime patching.

## Architecture

- **Source**: macOS DMG fetched via `fetchurl` (currently v1.13576.4 — tracked by github-actions auto-update)
- **Extraction**: `7zz` (native LZFSE support) + `asar_tool.py`
- **Runtime**: `electron_41` from nixpkgs
- **Packaging**: Nix flake with `makeWrapper` + `buildFHSEnv`

## Key Commands

```bash
# Build
nix build .                     # Default (FHS wrapper with Cowork + MCP)
nix build .#claude-app          # Just the patched app.asar

# Run
nix run .

# Validate
nix flake check

# Dev shell
nix develop
```

## Patching Workflow

Patches use `perl -pe` regex with `\w+` (or `[\w\$]+` where minified names contain `$`) wildcards for minified identifiers, so version bumps should not require patch changes.

1. **Fetch DMG URL**: Get from `https://claude.ai/download` (inspect download link in browser)
2. **Update hash**: `nix-prefetch-url <url>` then `nix hash convert --hash-algo sha256 --to sri <hash>`
3. **Update version/hash/URL** in `flake.nix`
4. **Build**: `nix build .` — if it succeeds, patches are still valid
5. **If build fails**: Check the `grep -qP` verification errors to see which regex needs updating

See `docs/patching-architecture.md` for the full technical analysis.

## Patch Chain

| # | Method | Purpose |
|---|--------|---------|
| 00 | File copy | Electron API stubs for Linux (`@ant/claude-native`) |
| 01 | Append IIFE | Load Cowork module |
| 02 | _retired (v1.13576.4)_ | Was: route Linux through TS VM path via the `_o=…==="win32"` boolean. That boolean pair was inlined away; VM selection is gone (always `@ant/claude-swift`, substituted by patch 06) and availability moved to patch 03. No flag remains to flip. |
| 03 | `perl -pe` regex | Return "supported" for Linux availability — injects into the unified availability fn (codename "yukonSilver", e.g. `Hce`). Subsumes old patch 02's availability role. |
| 04 | `perl -pe` regex | Skip macOS VM bundle download |
| 05 | Node.js dynamic | Create Linux session at VM start (spawn, writeStdin, mounts, path translation) |
| 06 | `perl -pe` regex | Return Linux VM instance from getters |
| 07 | Append IIFE | Replace "for Windows"/"for Mac" with "for Linux" |
| 08 | `perl -pe` regex | Use theme-aware PNGs for tray icon (08b targets the new `switch`-on-icon-type `case"template-image"` — theme-aware on Linux) |
| 09 | `perl -pe` regex | DBus tray cleanup delay for stability |
| 11 | `perl -pe` regex | Resolve `shellPathWorker.js` from Claude's asar (not Electron runtime's) |
| 12 | `perl -pe` regex | Neutralize `[1m]` model-suffix functions — unblocks Code/LOCAL send button. v1.13576.4 has **two** chained suffixers (`WcA` old-style + new `czA(A,e)`); both are neutralized to pass-through. |
| 13 | _retired (v1.13576.4)_ | `getHostPlatform()` now ships a native `linux-x64`/`linux-arm64` branch upstream; patch asserts the branch is present instead of injecting it. |
| 14 | `perl -pe` regex | Restore constructor's `CLAUDE_CODE_LOCAL_BINARY` → `initLocalBinary` wiring (minified into a dead expression in v1.6608.2) |
| 15 | _retired (v1.13576.4)_ | VM bundle lookup now hardcodes `fo.files["darwin"][arch]??[]` (no longer `files[process.platform]`), so the Linux undefined-key crash can't occur; patch asserts the dynamic form is gone. |
| 16 | `perl -pe` regex | Guard macOS-fork-only Electron **startup** APIs absent in stock `electron_41` — `systemPreferences.setUserDefault(…)` (darwin-guard) and `app.configureWebAuthn(…)` (existence-guard). Without these the app throws `… is not a function` at module load, before any window opens. |
| 17 | `perl -pe` regex | Guard macOS-only BrowserWindow chrome APIs (`setWindowButtonPosition`, `setHiddenInMissionControl`) via existence checks — these fire during window setup (async), surfacing as unhandled rejections + Sentry spam rather than blocking launch. |
| 18 | installPhase overlay | Replace the macOS Mach-O `node-pty` `pty.node` in `app.asar.unpacked` with a Linux-native build (`nodePtyElectron` derivation, built from node-pty 1.1.0-beta34 against `electron_41.headers`). Without it the in-app terminal/shell PTY fails to load (`Cannot find module .../pty.node`). N-API ⇒ ABI-stable; `spawn-helper` is macOS-only so it's left untouched. |

> **Custom Electron fork:** Anthropic's macOS build runs a patched Electron with extra native `app`/`systemPreferences`/`BrowserWindow` methods. Stock nixpkgs `electron_41` lacks them, so each top-level call to one throws on Linux. Patches 16–17 guard the ones hit on the launch path; if a future version adds more, the symptom is `TypeError: X.<method> is not a function` at startup — add an existence/darwin guard following the same pattern.

## Electron Gotchas

- **Process types**: Main (type='browser') vs renderer - only main can access Node.js
- **ASAR tool**: Use `tools/asar_tool.py` not `npx asar` (has bugs)
- **App caching**: Kill all processes with `pkill -f claude-desktop` before testing
- **ChildProcess objects**: Can't add methods via assignment - use Proxy

## Current State

See `COWORK_PROGRESS.md` for detailed status of Cowork Linux implementation.
