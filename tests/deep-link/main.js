// Regression test for patch 22 (scripts/linux-deep-link.js).
//
// Runs the *real* patch script inside a real Electron main process. The script is
// appended verbatim to the app's index.js at build time, so loading the same file
// here exercises exactly what ships.
//
// What this covers, and what it deliberately does not: the patch's contract is
// "acquire the lock, and on a second launch re-emit the app's own open-url
// listener with the URL from that launch's argv". Dispatch *after* open-url is
// upstream's code (mainView readiness, the pending-URL stash, window focus), so
// the test stands in a listener of its own and asserts the event arrives intact.
//
// Two roles, selected by CDT_ROLE:
//   primary  - takes the lock, waits for a delivery, prints the result
//   second   - launched with a claude:// argv; must hand off and exit 0 fast
const { app } = require("electron");
const path = require("path");
const fs = require("fs");

const ROLE = process.env.CDT_ROLE || "primary";
const OUT = process.env.CDT_OUT;
// CDT_SCRIPT_OVERRIDE exists so the suite can be run against a stand-in and
// prove it fails without the patch — a test for an "app silently does
// nothing" bug is worthless if it passes when the fix is absent.
const SCRIPT = process.env.CDT_SCRIPT_OVERRIDE ||
  path.join(__dirname, "..", "..", "scripts", "linux-deep-link.js");
const URL_ARG = "claude://login/google-auth?code=TESTCODE123";

let delivered = null;
// Stand in for the app's own listener. The patch must re-enter this, and must
// pass an event object carrying preventDefault() — the app calls it in a finally.
app.on("open-url", (event, url) => {
  if (typeof event.preventDefault !== "function") {
    delivered = "BAD_EVENT_no_preventDefault";
    return;
  }
  event.preventDefault();
  delivered = url;
});

// Load the patch exactly as the build appends it.
require(SCRIPT);

if (ROLE === "second") {
  // Losing the lock must have called app.exit(0) inside the require above, so
  // reaching here at all means the lock was NOT held by the primary.
  setTimeout(() => {
    console.log("SECOND_STILL_RUNNING");
    app.exit(3);
  }, 2000);
} else {
  app.whenReady().then(() => {
    const results = [];
    const check = (name, ok) => {
      results.push(`${ok ? "PASS" : "FAIL"} ${name}`);
      return ok;
    };

    // Reaching whenReady at all means the patch did not app.exit(0) us, i.e. we
    // won the lock. Assert it directly rather than by file existence: Chromium
    // only materializes SingletonLock/SingletonSocket once a browser window is
    // actually created, which this harness deliberately never does. (The real
    // app does create them — that is the manual check in CLAUDE.md.) Calling
    // requestSingleInstanceLock() again returns true for the holder.
    check("primary holds the single-instance lock",
      app.requestSingleInstanceLock() === true);

    // Spawn the second instance ASYNCHRONOUSLY. spawnSync would deadlock:
    // requestSingleInstanceLock() in the child notifies the primary and waits
    // for the ack, and a primary blocked in spawnSync can never send it.
    const { spawn } = require("child_process");
    const child = spawn(process.execPath, [__dirname, URL_ARG], {
      env: { ...process.env, CDT_ROLE: "second" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let childOut = "";
    child.stdout.on("data", (d) => (childOut += d));
    child.stderr.on("data", (d) => (childOut += d));

    const finish = (code) => {
      check("second instance exits 0 (handed off, no window)", code === 0);
      check("second instance did not stay up",
        !childOut.includes("SECOND_STILL_RUNNING"));
      // second-instance delivery is async; give the primary a moment.
      setTimeout(() => {
        check("primary received the URL via its own open-url listener",
          delivered === URL_ARG);
        if (delivered !== URL_ARG && delivered !== null) {
          results.push(`  (got: ${delivered})`);
        }
        const failed = results.filter((l) => l.startsWith("FAIL"));
        const out = results.join("\n") +
          `\nDEEPLINK_TEST_RESULT=${failed.length ? "FAIL" : "PASS"}\n`;
        console.log(out);
        if (OUT) fs.writeFileSync(OUT, out);
        app.exit(failed.length ? 1 : 0);
      }, 2000);
    };

    const guard = setTimeout(() => {
      results.push("FAIL second instance never exited (30s)");
      finish(-1);
    }, 30000);
    child.on("exit", (code) => { clearTimeout(guard); finish(code); });
  });
}
