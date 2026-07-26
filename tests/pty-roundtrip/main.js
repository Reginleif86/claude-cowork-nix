// Round-trips a real PTY through the Linux pty.node we overlay (patch 18a/18b),
// using the node-pty JS the DMG actually bundles. A version-mismatched addon
// loads fine and only fails here, on the first method the JS calls; a missing
// ASAR "unpacked" header entry fails even earlier, at require().
const { app } = require("electron");
const ASAR = process.env.CLAUDE_ASAR;

app.whenReady().then(async () => {
  const results = [];
  const ok = (name, pass) => { results.push([name, pass]); console.log((pass ? "PASS " : "FAIL ") + name); };

  try {
    const ptyPath = ASAR + "/node_modules/node-pty";
    console.log("node-pty JS version:", require(ptyPath + "/package.json").version);
    const pty = require(ptyPath);
    ok("require(node-pty) resolves addon", typeof pty.spawn === "function");

    // Interactive shell we keep alive so live-fd operations (resize) are valid.
    const term = pty.spawn("/bin/sh", [], {
      name: "xterm-color", cols: 80, rows: 24, cwd: "/tmp",
      env: Object.assign({}, process.env, { PS1: "" }),
    });
    ok("spawn() returns a pid", typeof term.pid === "number" && term.pid > 0);

    let buf = "";
    term.onData(d => { buf += d; });
    const waitFor = (re, ms = 8000) => new Promise((res, rej) => {
      const t0 = Date.now();
      const iv = setInterval(() => {
        const m = buf.match(re);
        if (m) { clearInterval(iv); res(m); }
        else if (Date.now() - t0 > ms) { clearInterval(iv); rej(new Error("timeout waiting for " + re + "; buf=" + JSON.stringify(buf))); }
      }, 50);
    });

    // 1. writeStdin -> shell executes -> output streams back.
    term.write("echo PTY_ROUNDTRIP_OK\n");
    await waitFor(/PTY_ROUNDTRIP_OK/);
    ok("write/onData round-trip", true);

    // 2. The child sees a real TTY with the winsize we asked for.
    buf = "";
    term.write("stty size\n");
    await waitFor(/24\s+80/);
    ok("initial winsize is 24x80", true);

    // 3. resize() on a LIVE fd, observed by the child via TIOCGWINSZ.
    term.resize(100, 30);
    buf = "";
    term.write("stty size\n");
    await waitFor(/30\s+100/);
    ok("resize() takes effect (30x100)", true);

    // 4. Clean exit propagates an exit code.
    const exited = new Promise(res => term.onExit(e => res(e)));
    term.write("exit 7\n");
    const { exitCode } = await exited;
    ok("exit code propagates (7)", exitCode === 7);
  } catch (e) {
    console.log("threw:", (e && e.stack) || e);
    results.push(["unexpected exception", false]);
  }

  const failed = results.filter(([, p]) => !p).length;
  console.log(failed === 0 ? "PTY_TEST_RESULT=PASS" : "PTY_TEST_RESULT=FAIL");
  app.exit(failed === 0 ? 0 : 1);
});
