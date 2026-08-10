// Exercises the DeviceRegistry hardware-key methods in the REAL
// modules/enhanced-claude-native-stub.js (not a copy), because the failure this
// covers is a contract mismatch, and a copy would drift out of sync with the thing
// that ships.
//
// Background: v1.26832.0 added DeviceRegistry attestation. The renderer's
// signAttestationPreimage handler calls hardwareKeyGetOrCreate/hardwareKeySign on
// @ant/claude-native. Missing them throws `TypeError: r.hardwareKeyGetOrCreate is
// not a function` on a retry loop, and the app cannot fall back — the DEV
// software-key path is compiled out of release builds (`function $(){return!1}`).
//
// The strict half of the contract is the signature encoding. The app pipes the
// signature through a DER parser (`Re` in the bundle) that hard-rejects anything
// that is not SEQUENCE{INTEGER r, INTEGER s} with r/s of 1..33 bytes. Node's
// 'ieee-p1363' dsaEncoding, or any curve other than P-256, fails there — at
// runtime, in an IPC handler, where it surfaces only as a log line.
//
// Run: node tests/device-key.test.js

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const Module = require('module');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'cdt-devkey-'));

// The stub destructures electron at module load and registers a
// 'browser-window-created' icon hook, so the fake has to cover load-time use too;
// only app.getPath is reachable from the code actually under test.
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

// ---------------------------------------------------------------------------
// The app's DER -> P1363 converter, transcribed from the bundle. If our signature
// encoding drifts, this is what rejects it — so assert against it directly rather
// than against a friendlier parser that would accept more.
// ---------------------------------------------------------------------------
function appDerToP1363(e) {
  let t = 0;
  if (e[t++] !== 48) throw err('SEQUENCE');
  const n = e[t++];
  if (n > 127 || t + n !== e.length) throw err('length');
  const r = readInt();
  const i = readInt();
  if (t !== e.length) throw err('trailing');
  return Buffer.concat([r, i]);

  function readInt() {
    if (e[t++] !== 2) throw err('INTEGER');
    const len = e[t++];
    if (len < 1 || len > 33) throw err('INTEGER length');
    let r2 = e.subarray(t, (t += len));
    if (r2.length === 33) {
      if (r2[0] !== 0) throw err('sign-bit pad');
      r2 = r2.subarray(1);
    }
    const out = Buffer.alloc(32);
    r2.copy(out, 32 - r2.length);
    return out;
  }
  function err(m) {
    return new Error(`malformed DER ECDSA signature (${m})`);
  }
}

let pass = 0;
let fail = 0;
const ok = (name, cond, extra) => {
  if (cond) {
    pass++;
    console.log(`PASS  ${name}`);
  } else {
    fail++;
    console.log(`FAIL  ${name}${extra ? ` — ${extra}` : ''}`);
  }
};

const ALIAS = 'deviceRegistry.acct_0123456789';

console.log('--- hardwareKeyGetOrCreate shape ---');
const handle = native.hardwareKeyGetOrCreate(ALIAS);
ok('isHardwareBacked is false (honest: no enclave on Linux)', handle.isHardwareBacked === false);
ok('publicKeySpki is a Buffer (app calls .toString("base64"))', Buffer.isBuffer(handle.publicKeySpki));

let pub = null;
try {
  pub = crypto.createPublicKey({ key: handle.publicKeySpki, format: 'der', type: 'spki' });
} catch (e) {
  /* reported below */
}
ok('publicKeySpki re-parses as DER SPKI', pub !== null);
ok(
  'key is EC P-256 (the parser assumes 32-byte r/s)',
  pub && pub.asymmetricKeyType === 'ec' && pub.asymmetricKeyDetails.namedCurve === 'prime256v1',
);

console.log('\n--- signature encoding (200 rounds: short r/s are intermittent) ---');
let verified = true;
let parsed = true;
let sized = true;
let firstErr = '';
for (let i = 0; i < 200; i++) {
  const msg = crypto.randomBytes(48);
  const der = native.hardwareKeySign(ALIAS, msg);
  if (!Buffer.isBuffer(der)) {
    parsed = false;
    firstErr = 'sign did not return a Buffer';
    break;
  }
  if (!crypto.verify('sha256', msg, { key: pub, dsaEncoding: 'der' }, der)) verified = false;
  try {
    if (appDerToP1363(der).length !== 64) sized = false;
  } catch (e) {
    parsed = false;
    if (!firstErr) firstErr = e.message;
  }
}
ok('every signature verifies against the reported public key', verified);
ok("every signature is accepted by the app's strict DER parser", parsed, firstErr);
ok('every P1363 conversion is exactly 64 bytes', sized);

console.log('\n--- device identity must be stable ---');
ok(
  'same alias returns the same key across calls',
  native.hardwareKeyGetOrCreate(ALIAS).publicKeySpki.equals(handle.publicKeySpki),
);
ok(
  'a different alias gets a different key',
  !native.hardwareKeyGetOrCreate('deviceRegistry.acct_other').publicKeySpki.equals(handle.publicKeySpki),
);
// Simulate a restart: drop the module's state and re-require from disk.
delete require.cache[require.resolve('../modules/enhanced-claude-native-stub.js')];
const reloaded = require('../modules/enhanced-claude-native-stub.js');
ok(
  'key survives a process restart (persisted, not per-launch)',
  reloaded.hardwareKeyGetOrCreate(ALIAS).publicKeySpki.equals(handle.publicKeySpki),
);

console.log('\n--- key material handling ---');
const keyDir = path.join(TMP, 'userData', 'device-keys');
const files = fs.existsSync(keyDir) ? fs.readdirSync(keyDir) : [];
ok('keys are stored under userData/device-keys', files.length > 0);
ok(
  'every key file is 0600',
  files.every((f) => (fs.statSync(path.join(keyDir, f)).mode & 0o777) === 0o600),
  files.map((f) => (fs.statSync(path.join(keyDir, f)).mode & 0o777).toString(8)).join(','),
);
ok('key dir is 0700', (fs.statSync(keyDir).mode & 0o777) === 0o700);
// The alias reaches a filename, so it must not be able to steer the path.
native.hardwareKeyGetOrCreate('../../../../../../tmp/cdt-devkey-escape');
const after = fs.readdirSync(keyDir);
ok(
  'a traversal-shaped alias stays inside the key dir',
  after.length === files.length + 1 && after.every((f) => /^[0-9a-f]{64}\.pem$/.test(f)),
);
ok('key material is not an enumerable property of the module', !Object.keys(native).some((k) => /key|pem|private/i.test(k)));

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\n${fail === 0 ? 'ALL TESTS PASSED' : 'TESTS FAILED'}  (pass=${pass} fail=${fail})`);
process.exit(fail ? 1 : 0);
