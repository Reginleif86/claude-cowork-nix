
// --- Patch 22: restore Linux single-instance ownership + claude:// delivery ---
//
// Appended to $BUILD_DIR/index.js, the main-process entry that requires every
// chunk, so this runs after the app has registered its own listeners but
// before "ready" — the only window in which requestSingleInstanceLock() is
// still useful. (Patch 01 appends to the same file, for the same reason.)
//
// Through v1.9255.2 the main process branched on platform:
//
//   isMac ? (app.on("open-url", ...), app.on("continue-activity", ...))
//         : app.requestSingleInstanceLock()
//             ? app.on("second-instance", (e, argv) => { focus(); dispatch(argv) })
//             : app.quit();
//
// v1.24012.9 dropped the non-darwin arm entirely and now registers "open-url",
// "will-continue-activity" and "continue-activity" unconditionally. All three
// are macOS-only Electron events, so on Linux nothing ever consumes a claude://
// URL. Two user-visible consequences:
//
//   1. No single-instance lock, so every `claude-desktop claude://...` launch
//      (i.e. every xdg-open of the scheme handler) becomes a second full app
//      sharing one --user-data-dir.
//   2. The URL sits unread in that new process's argv. There is no cold-start
//      argv scan for the scheme either, so it is simply dropped.
//
// The practical effect is that OAuth sign-in cannot complete on Linux at all:
// the app opens the system browser (ASWebAuthenticationSession, which returns
// the callback in-process, is macOS-only), and the claude://login/... callback
// never reaches the app. The user gets a fresh window still showing the stale
// "sign in again" banner, forever.
//
// This restores the missing arm without reimplementing any dispatch logic: the
// app's own "open-url" listener already does the real work (mainView readiness,
// the pending-URL stash for pre-ready arrivals, and window focus), so we simply
// re-emit that event. Keeping the app as the single owner of URL handling is
// what makes this patch cheap to carry across version bumps.

(function () {
  if (process.platform === "darwin") return;

  const { app, BrowserWindow } = require("electron");
  const SCHEME = "claude://";

  function urlFromArgv(argv) {
    if (!Array.isArray(argv)) return undefined;
    return argv.find(
      (a) => typeof a === "string" && a.startsWith(SCHEME)
    );
  }

  // Only used for a bare second launch (no URL). When there *is* a URL the
  // app's own handler focuses the window itself, after it knows the dispatch
  // succeeded. Deliberately not reaching for the chunk's `exports.mainWindow`:
  // that name is minifier output, whereas getAllWindows() is public API.
  function focusExistingWindow() {
    for (const w of BrowserWindow.getAllWindows()) {
      if (w.isDestroyed()) continue;
      if (w.isMinimized()) w.restore();
      if (!w.isVisible()) w.show();
      w.focus();
      return;
    }
  }

  function deliver(url) {
    // Re-enter the app's already-registered "open-url" listener. It calls
    // preventDefault() on the event in a finally block, so pass a stub.
    app.emit("open-url", { preventDefault() {} }, url);
  }

  // Losing the lock means another instance already owns the profile. Our argv
  // has been handed to it synchronously by requestSingleInstanceLock() itself
  // (Chromium's ProcessSingleton notifies the primary and waits for ack inside
  // that call), so there is nothing left for us to do but get out of the way.
  //
  // app.exit() rather than app.quit(): because this patch is appended to the end
  // of the chunk, the app has already registered its before-quit/onQuitCleanup
  // handlers, and app.quit() runs all of them — including flush-web-storage and
  // plan-usage-history, which write into the --user-data-dir that the primary
  // owns. A process that should never have started must not touch shared state
  // on its way out. app.exit() skips those handlers and terminates immediately.
  if (!app.requestSingleInstanceLock()) {
    app.exit(0);
    return;
  }

  app.on("second-instance", (_event, argv) => {
    const url = urlFromArgv(argv);
    if (url) {
      deliver(url);
      return;
    }
    focusExistingWindow();
  });

  // Cold start: the scheme handler launched us *as* the first instance (app was
  // not running when the user clicked the callback link). The app's handler
  // stashes the URL if mainView isn't up yet and replays it once it is, so
  // emitting at "ready" is early enough without being too early.
  const initialUrl = urlFromArgv(process.argv);
  if (initialUrl) {
    app.whenReady().then(() => deliver(initialUrl));
  }
})();
