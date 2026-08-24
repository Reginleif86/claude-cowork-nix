# Linux deep-link round-trip test (patch 22)

Verifies `scripts/linux-deep-link.js` — the restored non-darwin arm of the main
process's deep-link setup — inside a real Electron main process, by loading the
**same file the build appends** to `index.js`.

Covers issues #52 and #57: without this patch, every `xdg-open` of a `claude://`
URL starts a *second full app* against one `--user-data-dir` and the URL is never
read, so OAuth sign-in can never complete.

## Why this test exists

The failure mode is silent and structural: nothing crashes, no Sentry event
fires, and the window opens normally — there is just an extra window each time
and a login that never completes. A headless launch cannot see it, because the
damage is that a *second process starts*. So the test drives two processes.

## What it asserts

| Check | Catches |
|---|---|
| primary holds the single-instance lock | the patch exited the process that should have won |
| second instance exits 0 | the losing instance became a second full app |
| second instance did not stay up | as above, observed from its own stdout |
| primary received the URL via its own `open-url` listener | argv scanned but never delivered, or delivered without a `preventDefault`-bearing event |

The last three carry the test. The lock check is weaker than it looks: in the
negative control `app.requestSingleInstanceLock()` acquires the lock as a side
effect of asking, so it passes even with the patch absent.

The test stands in its own `open-url` listener rather than asserting on app
behaviour, because dispatch past that event is upstream's code (mainView
readiness, the pending-URL stash, window focus). The patch's contract stops at
re-emitting the event intact — including an event object with a working
`preventDefault()`, which the app calls in a `finally`.

## Run

```bash
ELECTRON=$(nix build --no-link --print-out-paths --impure \
  --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux.electron_41')

TMPH=$(mktemp -d /tmp/cddl-XXXX)   # never the real HOME: this writes a user-data-dir
RT=$(mktemp -d /tmp/cdlr-XXXX)     # must be short: unix socket paths cap at 108 bytes
env -u WAYLAND_DISPLAY -u DISPLAY -u XDG_SESSION_TYPE \
  HOME="$TMPH" XDG_RUNTIME_DIR="$RT" \
  xvfb-run -a "$ELECTRON/bin/electron" tests/deep-link --no-sandbox
```

Passes when it prints `DEEPLINK_TEST_RESULT=PASS` (exit 0).

## Negative control

A test for a "the app silently does nothing" bug is worthless if it passes when
the fix is absent. `CDT_SCRIPT_OVERRIDE` points the harness at a stand-in:

```bash
: > /tmp/empty-patch.js
CDT_SCRIPT_OVERRIDE=/tmp/empty-patch.js  # ...same command as above
```

Expect three FAILs and exit 1. If that run passes, the harness has stopped
testing anything — fix it before trusting a green run.

## Gotchas

- **Spawn the second instance asynchronously.** `spawnSync` deadlocks:
  `requestSingleInstanceLock()` in the child notifies the primary and waits for
  the ack, and a primary blocked in `spawnSync` can never send it. The symptom
  is a SIGKILL (exit 137) with no output at all.
- **No `SingletonLock` file appears here.** Chromium materializes those only once
  a browser window is created, which this harness deliberately never does. The
  real app does create them — that check is in CLAUDE.md's manual list.
