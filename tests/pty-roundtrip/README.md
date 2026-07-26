# node-pty round-trip test (patch 18)

Verifies the Linux `pty.node` overlay end to end, inside a real Electron main
process, using the node-pty JS the DMG bundles.

Two failure modes this catches that the Nix build cannot:

1. **Missing ASAR `unpacked` header entry.** Staging the binary at
   `app.asar.unpacked/.../build/Release/pty.node` is not enough — Electron only
   redirects the read when the ASAR header carries that file entry with
   `"unpacked": true`. Without it, `require("node-pty")` throws
   `Cannot find module './prebuilds/linux-x64/pty.node'` at runtime.
2. **node-pty JS ↔ addon version drift.** N-API keeps the ABI stable, so a
   mismatched addon loads cleanly and then throws on the first method the JS
   calls.

## Run

```bash
APPASAR=$(nix build .#claude-app --no-link --print-out-paths | tail -1)
ELECTRON=$(nix build --no-link --print-out-paths --impure \
  --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux.electron_41')

RT=$(mktemp -d /tmp/pty-XXXX)   # must be short: unix socket paths cap at 108 bytes
env -u WAYLAND_DISPLAY -u DISPLAY -u XDG_SESSION_TYPE \
  XDG_RUNTIME_DIR="$RT" CLAUDE_ASAR="$APPASAR/lib/claude-desktop/app.asar" \
  xvfb-run -a "$ELECTRON/bin/electron" tests/pty-roundtrip --no-sandbox
```

Use the flake's pinned `electron_41`, not whatever `nixpkgs#electron_41` resolves
to today — the addon is built against the pinned version's headers.

Passes when it prints `PTY_TEST_RESULT=PASS` (exit 0). Covers: addon resolution,
`spawn()`, `write`/`onData` round-trip, initial winsize, live `resize()` observed
by the child via `stty size`, and exit-code propagation.
