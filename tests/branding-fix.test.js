// Minimal DOM harness to exercise scripts/branding-fix.js against the
// corruption scenarios reported in issue #40, plus the chrome relabel it is
// supposed to keep doing.
const fs = require("fs");

let pendingMutations = [];
let observerCb = null;

class Node {
  constructor(nodeType) {
    this.nodeType = nodeType;
    this.childNodes = [];
    this.parentElement = null;
  }
}

class Text extends Node {
  constructor(text) {
    super(3);
    this._text = text;
  }
  get textContent() { return this._text; }
  set textContent(v) { this._text = v; }
}

class Element extends Node {
  constructor(tag, attrs = {}) {
    super(1);
    this.tag = tag.toLowerCase();
    this.attrs = attrs;
  }
  append(...kids) {
    for (const k of kids) { k.parentElement = this; this.childNodes.push(k); }
    return this;
  }
  // Supports the selector forms branding-fix.js actually uses:
  //   tag, [attr], [attr="v"], [attr*="v"], .class
  matches(selectorList) {
    return selectorList.split(",").map(s => s.trim()).some(sel => this._matchOne(sel));
  }
  _matchOne(sel) {
    if (sel.startsWith(".")) {
      const cls = sel.slice(1);
      return (this.attrs.class || "").split(/\s+/).includes(cls);
    }
    const attrMatch = sel.match(/^\[([\w-]+)(?:(\*?=)"([^"]*)")?\]$/);
    if (attrMatch) {
      const [, name, op, val] = attrMatch;
      if (!(name in this.attrs)) return false;
      if (!op) return true;
      const actual = String(this.attrs[name]);
      return op === "*=" ? actual.includes(val) : actual === val;
    }
    return this.tag === sel.toLowerCase();
  }
  closest(selectorList) {
    let cur = this;
    while (cur) {
      if (cur.matches(selectorList)) return cur;
      cur = cur.parentElement;
    }
    return null;
  }
}

const document = {
  readyState: "complete",
  title: "Claude for Mac",
  body: new Element("body"),
  addEventListener() {},
};

global.document = document;
global.window = { addEventListener() {} };
global.process = process;
global.MutationObserver = class {
  constructor(cb) { observerCb = cb; }
  observe(target, opts) { this.opts = opts; observedOpts = opts; }
};
let observedOpts = null;

// --- build a document that mixes chrome and content ---------------------------
const downloadBtn = new Element("button").append(new Text("Download for Mac"));
const menuItem = new Element("div", { class: "menu-item" }).append(new Text("Claude for Windows"));

const composer = new Element("div", { contenteditable: "true" });
const composerText = new Text("how do I build this for Windows?");
composer.append(composerText);

const transcript = new Element("div", { "data-testid": "conversation-turn" });
const responseEl = new Element("div", { class: "font-claude-response" });
const responseText = new Text("You should use the MSVC toolchain for Windows when targeting it.");
responseEl.append(responseText);
transcript.append(responseEl);

const codeBlock = new Element("pre").append(new Text("# build for Windows\nmake win32"));

const prose = new Element("p");
const proseText = new Text(
  "This is a long help paragraph that goes on and on explaining many different things " +
  "to the reader, and somewhere in the middle it happens to mention building for Windows " +
  "as an aside, which is prose rather than a platform label on a button."
);
prose.append(proseText);

document.body.append(downloadBtn, menuItem, composer, transcript, codeBlock, prose);

// --- run the patch -----------------------------------------------------------
process.platform = "linux";
const src = fs.readFileSync(require("path").join(__dirname, "..", "scripts", "branding-fix.js"), "utf8");
eval(src);

// --- assertions --------------------------------------------------------------
let failures = 0;
function check(name, actual, expected) {
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}`);
  if (!ok) console.log(`        expected: ${JSON.stringify(expected)}\n        actual:   ${JSON.stringify(actual)}`);
}

console.log("--- chrome should be relabeled ---");
check("download button relabeled", downloadBtn.childNodes[0].textContent, "Download for Linux");
check("menu item relabeled", menuItem.childNodes[0].textContent, "Claude for Linux");
check("document.title relabeled", document.title, "Claude for Linux");

console.log("\n--- content must be untouched (issue #40) ---");
check("composer text untouched", composerText.textContent, "how do I build this for Windows?");
check("model response untouched", responseText.textContent, "You should use the MSVC toolchain for Windows when targeting it.");
check("code block untouched", codeBlock.childNodes[0].textContent, "# build for Windows\nmake win32");
check("long prose untouched", proseText.textContent.includes("for Windows"), true);

console.log("\n--- observer configuration ---");
check("characterData not observed", !observedOpts.characterData, true);
check("childList observed", observedOpts.childList === true, true);

console.log("\n--- streamed characterData mutation must be ignored ---");
// Simulate a streamed chunk: the app mutates an existing text node's data.
responseText.textContent = "Here is the answer for Windows users.";
observerCb([{ type: "characterData", target: responseText, addedNodes: null }]);
check("streamed chunk untouched", responseText.textContent, "Here is the answer for Windows users.");

console.log("\n--- newly added chrome is still caught ---");
const lateBtn = new Element("a").append(new Text("Get it for Mac"));
document.body.append(lateBtn);
observerCb([{ type: "childList", addedNodes: [lateBtn] }]);
check("late-added chrome relabeled", lateBtn.childNodes[0].textContent, "Get it for Linux");

console.log("\n--- newly added content is still skipped ---");
const lateMsg = new Element("div", { "data-testid": "message-content" }).append(new Text("compile for Windows first"));
document.body.append(lateMsg);
observerCb([{ type: "childList", addedNodes: [lateMsg] }]);
check("late-added content untouched", lateMsg.childNodes[0].textContent, "compile for Windows first");

console.log(`\n${failures === 0 ? "ALL TESTS PASSED" : failures + " TEST(S) FAILED"}`);
process.exit(failures === 0 ? 0 : 1);
