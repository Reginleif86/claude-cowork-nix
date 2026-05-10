# Claude Cowork Nix

[![Nix Flake](https://img.shields.io/badge/Nix-Flake-5277C3?logo=nixos&logoColor=white)](https://github.com/Reginleif88/claude-cowork-nix)
[![Platform](https://img.shields.io/badge/Platform-Linux-blue?logo=linux&logoColor=white)](https://github.com/Reginleif88/claude-cowork-nix)
[![License](https://img.shields.io/badge/License-Apache--2.0%20OR%20MIT-blue)](./LICENSE-APACHE)
[![Claude Desktop](https://img.shields.io/badge/Claude_Desktop-v1.6608.2-d97757)](https://claude.ai)
[![Cowork](https://img.shields.io/badge/Cowork-Enabled-green)](./COWORK_PROGRESS.md)

Fully declarative NixOS package for Claude Desktop on Linux with Cowork support. Extracts from the macOS DMG, patches for Linux compatibility, and wraps with Electron 41.

> Originally created by [Tom Cassady (@heytcass)](https://github.com/heytcass).
> Based on [claude-desktop-linux-flake](https://github.com/heytcass/claude-desktop-linux-flake).
> Codebase maintained with [Claude Code](https://claude.ai/code).
>
> **This is not an official Anthropic product.** Claude Desktop is property of Anthropic.

## Prerequisites

Nix with flakes enabled:

```bash
# NixOS users: already have Nix
# Others: install Nix
sh <(curl -L https://nixos.org/nix/install) --daemon

# Enable flakes (add to ~/.config/nix/nix.conf)
experimental-features = nix-command flakes
```

## Quick Start

```bash
# Run directly
nix run github:Reginleif88/claude-cowork-nix

# Install to profile
nix profile install github:Reginleif88/claude-cowork-nix
```

### NixOS Module

```nix
# flake.nix
{
  inputs.claude-cowork-nix.url = "github:Reginleif88/claude-cowork-nix";

  outputs = { self, nixpkgs, claude-cowork-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-cowork-nix.nixosModules.default
        ({ pkgs, ... }: {
          programs.claude-desktop = {
            enable = true;
            fhs = true;   # Use FHS wrapper (default: true)

            # OPTIONAL — enables Code section's LOCAL sub-mode. Wires
            # CLAUDE_CODE_LOCAL_BINARY so CCD uses this binary instead of
            # trying to download one (which throws on Linux).
            # claudeCodePackage = pkgs.claude-code;
          };
        })
      ];
    };
  };
}
```

### Home Manager Module

```nix
{ pkgs, ... }: {
  imports = [ claude-cowork-nix.homeManagerModules.default ];
  programs.claude-desktop = {
    enable = true;
    fhs = true;               # FHS wrapper (default: true)
    createDesktopEntry = true; # XDG desktop entry (default: true)

    # OPTIONAL — enables Code section's LOCAL sub-mode
    # claudeCodePackage = pkgs.claude-code;
  };
}
```

## Enabling the Code section's LOCAL mode

The in-app "Code" section has four sub-modes (LOCAL, SSH, Cloud Environment, Remote Control). SSH / Cloud / Remote Control work out-of-the-box because they bypass the local CCD daemon. **LOCAL requires opt-in** on Linux because Anthropic's CCD daemon throws `Unsupported platform: linux-x64` when trying to download its own claude-code binary.

### How it works

Anthropic's CCD daemon has an undocumented escape hatch: if `CLAUDE_CODE_LOCAL_BINARY` is set to a valid executable path, *every* CCD entry point (`getStatus`, `prepare`, `getBinaryPathIfReady`, `prepareForVM`) short-circuits before the `getHostPlatform` throw. The `claudeCodePackage` option wires this env var into the Electron wrapper at build time.

In v1.6608.2 Anthropic minified the constructor's env-var bridge into a dead expression, breaking the escape hatch on disk. **Patch 14** restores the original constructor wiring (`process.env.CLAUDE_CODE_LOCAL_BINARY && (this.localBinaryInitPromise = this.initLocalBinary(env))`), so `claudeCodePackage` works again. **Patch 13** is a defensive belt-and-braces fix: it makes `getHostPlatform()` return `linux-x64`/`linux-arm64` instead of throwing — needed because v1.6608.2 also added new send-pipeline call sites that `await Ta.prepare()` from Cowork chats, which would otherwise crash with "Something went wrong / Unsupported platform: linux-x64" even when `claudeCodePackage` is unset.

Patch 12 additionally neutralizes an Anthropic GrowthBook feature flag (`3885610113`) that would otherwise append `[1m]` to Opus/Sonnet model IDs, causing `model_configs/claude-opus-4-6[1m]` 404s that disable the send button. Patch 12 applies unconditionally — you get the fix whether or not you opt into LOCAL mode.

### Three ways to provide a claude-code binary

**Option A — from nixpkgs** (stable, currently v2.1.92):

```nix
programs.claude-desktop = {
  enable = true;
  claudeCodePackage = pkgs.claude-code;
};
```

**Option B — from a community flake** (e.g. [claude-code-nix](https://github.com/sadjow/claude-code-nix), tracks upstream closely):

```nix
# In your outer flake inputs:
inputs.claude-code.url = "github:sadjow/claude-code-nix";
inputs.claude-code.inputs.nixpkgs.follows = "nixpkgs";

# In your home.nix / config:
{ pkgs, inputs, ... }:
let system = pkgs.stdenv.hostPlatform.system; in {
  programs.claude-desktop = {
    enable = true;
    claudeCodePackage = inputs.claude-code.packages.${system}.default;
  };
}
```

If you already have `inputs.claude-code.packages.${system}.default` in `home.packages`, reuse that same reference — Nix deduplicates, so there's only one claude-code derivation in the store.

**Option C — external env var** (for custom setups, e.g. auth wrappers):

Leave `claudeCodePackage` unset and export `CLAUDE_CODE_LOCAL_BINARY` in your session env (not just your shell rc — the desktop entry won't source that). For example, in `~/.profile`:

```bash
export CLAUDE_CODE_LOCAL_BINARY="$HOME/.local/bin/claude-wrapper.sh"
```

The wrapper option uses `makeWrapper --set-default`, so any externally-set `CLAUDE_CODE_LOCAL_BINARY` wins over the module's baked-in path.

### Why installing `claude-code` via `home.packages` isn't enough

Putting claude-code in `home.packages` only adds `claude` to your shell's PATH. The CCD daemon inside the Electron process doesn't call `which claude` — it reads one specific env var:

```js
// From Claude Desktop's extracted index.js:
const r = process.env.CLAUDE_CODE_LOCAL_BINARY;
r && (this.localBinaryInitPromise = this.initLocalBinary(r))
```

No PATH fallback exists. `claudeCodePackage` bridges the gap: it references the same store path your shell already has, and bakes the `export CLAUDE_CODE_LOCAL_BINARY=…` line into the claude-desktop launcher script.

### Verifying it works

After rebuilding home-manager / the NixOS config:

```bash
# Confirm the wrapper has the env var
grep CLAUDE_CODE_LOCAL_BINARY "$(readlink -f $(which claude-desktop))"
# Expected: export CLAUDE_CODE_LOCAL_BINARY=${CLAUDE_CODE_LOCAL_BINARY-'/nix/store/.../claude-code-.../bin/claude'}

# Launch and check logs for the LOCAL OVERRIDE message
claude-desktop 2>&1 | grep -i "LOCAL OVERRIDE\|CCD"
# Expected: [CCD] LOCAL OVERRIDE: Using local binary at /nix/store/.../bin/claude
```

Then open **Code → LOCAL** in the app, pick a working directory, and send a message. The send button should activate and Claude should stream a response.

### Auth caveat

The Electron-spawned claude-code inherits only the desktop app's env — not your interactive shell's. If you rely on a shell-level auth toggle (e.g. a `claude-provider --env` wrapper that switches between Anthropic and a third-party provider), LOCAL mode will silently fall back to whatever auth is stored in `~/.claude/` (typically your Claude Desktop sign-in). For provider toggling, point `claudeCodePackage` at a thin wrapper derivation that sources your provider env before `exec`-ing the real binary, or use Cowork chats which inherit the desktop app's auth.

## Package Variants

| Package | Description |
|---------|-------------|
| `default` | FHS-wrapped Claude Desktop with Cowork, MCP, and `/sessions` path support |
| `claude-app` | Just the patched app.asar (for custom wrappers) |
| `asar-tool` | Python ASAR extract/pack tool (development) |

The default package wraps Claude in a `buildFHSEnv` environment with `/usr/bin/bwrap`, `/usr/bin/node`, `/usr/bin/python3`, standard library paths, common tools (git, curl, docker-client, coreutils), and a `/sessions` symlink for Cowork VM path resolution.

## What Works

- **Sign-in** via Google OAuth / SSO (opens system browser, returns via deep link)
- **Native Wayland** support (not XWayland) via `--ozone-platform-hint=auto`
- **Persistent auth tokens** via `--password-store=gnome-libsecret` (works with KDE Wallet, GNOME Keyring, or any `org.freedesktop.secrets` provider)
- **HiDPI scaling** (sharp rendering)
- **Window decorations** with titlebar overlay
- **Claude Code** tool execution
- **File uploads and downloads**
- **Full chat** functionality
- **Cowork** sessions with Claude Code — multi-turn, file ops, directory picker, transcript persistence (see [COWORK_PROGRESS.md](./COWORK_PROGRESS.md))

## The "Code" section

The Claude Code section in the left sidebar has four sub-modes. Status on Linux:

| Mode | Status | Notes |
|------|--------|-------|
| **LOCAL** (spawn Claude Code on this machine) | ✅ Works (opt-in) | Set `programs.claude-desktop.claudeCodePackage = pkgs.claude-code;` (or point at any compatible claude-code derivation). This wires `CLAUDE_CODE_LOCAL_BINARY`, which the CCD daemon detects and uses to short-circuit the `getHostPlatform` throw. Patch 14 restores the constructor's env-var bridge that v1.6608.2 minified away; patch 12 neutralizes a GrowthBook feature flag (`3885610113`) that would otherwise 404 model config requests and disable the send button. |
| **SSH** (run Claude Code on a remote host via SSH) | ✅ Works | Bypasses local CCD; the web UI talks directly to the remote. |
| **Cloud Environment** (Anthropic-managed) | ✅ Works | Same as SSH — bypasses local platform gates. |
| **Remote Control** | ✅ Works | Same as SSH. |

**Without `claudeCodePackage` set**, LOCAL mode remains unavailable (CCD has no binary to use), but SSH / Cloud / Remote Control still work. Cowork chats remain a fully-featured alternative: same agent capabilities through the older local-agent IPC path. Patch 13 ensures Cowork itself is unaffected by the CCD `getHostPlatform` throw that v1.6608.2 added to the chat send pipeline. See [COWORK_PROGRESS.md](./COWORK_PROGRESS.md) for the full investigation and design notes.

**Auth caveat**: the Electron-spawned `claude-code` inherits only the desktop app's env, not your shell's. If you rely on a shell-level auth wrapper (e.g. `claude-provider --env` toggling between Anthropic and a provider), LOCAL mode will silently use whatever auth is stored in `~/.claude/` (typically your Claude Desktop sign-in). For provider toggling, point `claudeCodePackage` at a thin wrapper script that sources your provider env before `exec`-ing the real binary, or leave it unset and use Cowork chats.

## Architecture

```
macOS DMG (fetchurl)
       |
  7zz (LZFSE) -> app.asar
       |
  asar_tool.py extract -> raw JS
       |
  14 patches:
    00: Native module stub (@ant/claude-native + AuthRequest)
    01: Cowork module loader (claude-cowork-linux)
    02: Platform flag (route Linux through TypeScript VM path)
    03: Availability check (return "supported" for Linux)
    04: Skip bundle download (short-circuit on Linux)
    05: VM start intercept (Linux session with spawn, writeStdin, mounts)
    06: VM getter override (return Linux VM instance)
    07: Platform branding ("for Linux" in UI)
    08: Tray icon (theme-aware PNGs for Linux)
    09: DBus tray cleanup delay (stability fix)
    11: shellPathWorker resolution (use process.argv[1], not resourcesPath)
    12: [1m] model-suffix neutralization (unblocks Code/LOCAL send button)
    13: getHostPlatform Linux return (stops "Unsupported platform: linux-x64" throw)
    14: CLAUDE_CODE_LOCAL_BINARY constructor wiring (restored in v1.6608.x)
       |
  asar_tool.py pack -> patched app.asar
       |
  electron_41 + makeWrapper + buildFHSEnv -> claude-desktop
```

Claude Desktop has two VM paths: macOS via `@ant/claude-swift` (Swift native module) and Windows via a TypeScript VM client over IPC sockets. By setting the platform flag (patch 02), Linux routes through the TypeScript path. The VM start function (patch 05) creates a Linux session that spawns Claude Code directly on the host, translates VM-internal paths to real host paths, and manages process I/O via the SDK wire protocol.

## Project Structure

```
.
├── flake.nix                         # Full NixOS package definition
├── modules/
│   ├── claude-cowork-linux.js        # Cowork session manager
│   └── enhanced-claude-native-stub.js # Linux native module replacement
├── scripts/
│   ├── branding-fix.js               # Platform branding patch
│   ├── cowork-init.js                # Cowork initialization
│   ├── cowork-plugin-shim.sh         # Plugin permission bridge (filesystem IPC)
│   └── patch-vm-start.js             # VM start intercept (spawn, writeStdin, mounts)
├── tools/
│   ├── asar_tool.py                  # ASAR archive extract/pack
│   └── icns_extract.py               # macOS icon extraction
└── examples/                         # NixOS/Home Manager config examples
```

## Development

```bash
# Enter dev shell with all tools
nix develop

# Build and test
nix build .
nix flake check                 # Validate structure

# Launch and check logs
nix run . 2>&1 | grep -E "Cowork|error"
```

### Updating to New Versions

A daily GitHub Actions workflow (`.github/workflows/auto-update.yml`) discovers the latest DMG via Anthropic's CDN `RELEASES.json`, prefetches the SRI hash, opens a PR, and verifies the build. Most version bumps land cleanly through CI because patches anchor on `\w+`/`[\w$]+` wildcards over minified identifiers and stable English log strings.

To update manually (e.g. before the daily cron fires):

1. Resolve the latest version + DMG URL:

   ```bash
   curl -s https://downloads.claude.ai/releases/darwin/universal/RELEASES.json \
     | jq -r '"\(.currentRelease)\t\(.releases[0].updateTo.url | sub("\\.zip$"; ".dmg"))"'
   ```

2. Prefetch the hash and update `flake.nix`:

   ```bash
   nix_hash=$(nix-prefetch-url --type sha256 "<DMG_URL>")
   nix hash convert --hash-algo sha256 --to sri "$nix_hash"
   ```

   Then update `claudeVersion`, `claudeDmgUrl`, and `claudeDmgHash`.
3. Build: `nix build .` — if it succeeds, all patches still apply.
4. If build fails: the `grep -qP` verification line (or the dynamic patch-05 script's error) names the patch whose regex needs widening. Check `docs/patching-architecture.md` for context. Past breakages have come from Anthropic adding intermediate code inside an anchored function body — typically fixed by relaxing one regex to allow a lazy `.{0,N}?` gap.

## Troubleshooting

### Build Fails at DMG Extraction

The build uses `7zz` which supports LZFSE-compressed DMGs natively. If extraction fails, check if the DMG URL is still valid by downloading it in a browser from `https://claude.ai/download`.

### Wayland Issues

The wrapper passes `--ozone-platform-hint=auto`. To force Wayland:

```bash
claude-desktop --ozone-platform=wayland
```

### Cowork Not Appearing

```bash
nix build . -L 2>&1 | grep -E "patch|applied|WARNING|ERROR"
```

All patches should show "applied" with no "WARNING" lines.

### Bubblewrap Permission Errors

On some systems, user namespaces may be restricted:

```bash
sysctl kernel.unprivileged_userns_clone
# Should be 1. If 0:
sudo sysctl kernel.unprivileged_userns_clone=1
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT License](LICENSE-MIT), at your option.

Claude Desktop itself is property of Anthropic. This project provides only the packaging and patching code.
