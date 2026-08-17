// Exercises readProcessFootprints in the REAL
// modules/enhanced-claude-native-stub.js (not a copy).
//
// Background: v1.32352.0 added a process-memory sampler that calls this once a
// minute with an array of pids. Its guard is `if (!nativeModule) return nulls`,
// which our stub passes, so a missing method throws
// `TypeError: n.readProcessFootprints is not a function` on every tick. It is
// caught, logged as "[process-memory] snapshot failed", and never reaches Sentry —
// so nothing in the build or the headless launch notices. It took a 15-minute
// signed-in session to surface it.
//
// Contract, derived from the consumer:
//   - returns a real Promise (the caller does .finally() on it immediately)
//   - resolves to an array parallel to the input pids
//   - each element is null, or { footprintBytes, commitBytes }
//   - never resolves to the string "timeout" (the caller's 5s race sentinel)
//
// Run: node tests/process-footprints.test.js

const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'cdt-fp-'));

const fakeElectron = {
  app: {
    getPath: (what) => path.join(TMP, what),
    getAppPath: () => path.join(TMP, 'app.asar'),
    on() {},
  },
  BrowserWindow: class {},
  Notification: class {},
  nativeImage: { createFromPath: () => ({ isEmpty: () => true }) },
  nativeTheme: { shouldUseDarkColors: false, on() {} },
};
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === 'electron') return 'electron';
  return origResolve.call(this, request, ...rest);
};
require.cache.electron = { id: 'electron', filename: 'electron', loaded: true, exports: fakeElectron };

const native = require('../modules/enhanced-claude-native-stub.js');

let pass = 0;
let fail = 0;
const ok = (name, cond, extra) => {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}${extra ? ` — ${extra}` : ''}`); }
};

(async () => {
  const self = process.pid;

  const ret = native.readProcessFootprints([self]);
  ok('returns a thenable with .finally (caller uses it)',
     ret && typeof ret.then === 'function' && typeof ret.finally === 'function');

  const one = await ret;
  ok('resolves to an array', Array.isArray(one));
  ok('is not the string "timeout" (race sentinel)', one !== 'timeout');
  ok('one pid in -> one entry out', one.length === 1);
  ok('own process reports a footprint', one[0] && typeof one[0].footprintBytes === 'number');
  ok('footprint is a plausible RSS (1MB..8GB)',
     one[0] && one[0].footprintBytes > 1024 * 1024 && one[0].footprintBytes < 8 * 1024 ** 3,
     one[0] && String(one[0].footprintBytes));
  ok('commitBytes is null (no honest Linux equivalent)', one[0] && one[0].commitBytes === null);

  // Cross-check against Node's own view of RSS — same source, so they should be close.
  const nodeRss = process.memoryUsage().rss;
  const delta = Math.abs(one[0].footprintBytes - nodeRss) / nodeRss;
  ok('footprint agrees with process.memoryUsage().rss within 25%', delta < 0.25,
     `stub=${one[0].footprintBytes} node=${nodeRss} delta=${(delta * 100).toFixed(1)}%`);

  console.log('\n--- ordering and unavailable entries ---');
  // A pid that cannot exist: the array must stay parallel, with null in that slot.
  const mixed = await native.readProcessFootprints([self, 2 ** 30, self]);
  ok('array stays parallel to input', mixed.length === 3);
  ok('missing process yields null, not a throw', mixed[1] === null);
  ok('surrounding entries still resolve', mixed[0] !== null && mixed[2] !== null);

  console.log('\n--- hostile / degenerate input must not throw ---');
  for (const [label, input] of [
    ['empty array', []],
    ['non-array', null],
    ['negative pid', [-1]],
    ['zero pid', [0]],
    ['non-numeric pid', ['../../etc/passwd']],
    ['float pid', [1.5]],
  ]) {
    let res, threw = false;
    try { res = await native.readProcessFootprints(input); } catch { threw = true; }
    ok(`${label} resolves to an array without throwing`, !threw && Array.isArray(res));
  }
  // A path-shaped pid must never be interpolated into /proc/<pid>/status.
  const evil = await native.readProcessFootprints(['1/../../../etc/passwd']);
  ok('path-shaped pid is rejected as null', evil[0] === null);

  fs.rmSync(TMP, { recursive: true, force: true });
  console.log(`\n${fail === 0 ? 'ALL TESTS PASSED' : 'TESTS FAILED'}  (pass=${pass} fail=${fail})`);
  process.exit(fail ? 1 : 0);
})();
