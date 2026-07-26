
;(function() {
  if (process.platform !== "linux") return;

  // Cosmetic relabel of the macOS build's platform strings ("… for Mac") in app
  // chrome, so a Linux user doesn't read "for Mac" in their own UI.
  //
  // Deliberately conservative. The original version observed document.body with
  // characterData:true and rewrote every matching text node, which meant it also
  // rewrote *content*: typing "for Windows" in the composer mutated it to "for
  // Linux" as you typed, and each streamed chunk of a model response containing
  // the phrase was silently altered (issue #40). Relabeling chrome is cosmetic;
  // corrupting user input and model output is not. So the rules here are:
  //
  //   1. childList only — never characterData. Live-typed and streamed text
  //      arrives as characterData mutations, so it is structurally untouchable.
  //   2. Never descend into content regions (composer, transcript, code blocks).
  //   3. Only rewrite short text nodes; prose that merely mentions the phrase is
  //      not a platform label.
  //
  // Trade-off: a chrome label whose text is swapped in place after first render
  // (a characterData update on an existing node) is no longer caught. Platform
  // labels are static, so in practice the initial scan plus childList covers them.

  var PLATFORM_RE = /for (?:Windows|Mac)\b/g;

  // Regions whose text the user authors or the model streams. Anything inside
  // these is content, never chrome.
  var CONTENT_SELECTOR = [
    "[contenteditable]",
    "textarea",
    "input",
    "code",
    "pre",
    '[role="textbox"]',
    '[role="log"]',
    '[data-testid*="message"]',
    '[data-testid*="conversation"]',
    '[data-testid*="composer"]',
    '[data-testid*="chat"]',
    ".font-claude-response"
  ].join(",");

  // Platform labels are button/menu text. Anything longer is prose.
  var MAX_LABEL_LENGTH = 120;

  function isContentElement(el) {
    if (!el || typeof el.matches !== "function") return false;
    try {
      return el.matches(CONTENT_SELECTOR);
    } catch (e) {
      return false;
    }
  }

  function isInsideContent(textNode) {
    var el = textNode.parentElement;
    if (!el) return true; // detached: cannot prove it is chrome, so leave it
    if (typeof el.closest !== "function") return false;
    try {
      return el.closest(CONTENT_SELECTOR) !== null;
    } catch (e) {
      return false;
    }
  }

  function rewriteTextNode(textNode) {
    var t = textNode.textContent;
    if (!t || t.length > MAX_LABEL_LENGTH) return;
    // String.replace resets a global regex's lastIndex, so PLATFORM_RE stays
    // stateless here — unlike RegExp.test, which would not.
    var next = t.replace(PLATFORM_RE, "for Linux");
    if (next === t) return;
    if (isInsideContent(textNode)) return;
    textNode.textContent = next;
  }

  function walk(node) {
    if (node.nodeType === 3) {
      rewriteTextNode(node);
      return;
    }
    if (node.nodeType !== 1) return;
    if (isContentElement(node)) return; // prune the whole content subtree
    var children = node.childNodes;
    for (var i = 0; i < children.length; i++) walk(children[i]);
  }

  function fixTitle() {
    var t = document.title;
    if (!t) return;
    var next = t.replace(PLATFORM_RE, "for Linux");
    if (next !== t) document.title = next;
  }

  function scanDocument() {
    if (document.body) walk(document.body);
    fixTitle();
  }

  var observer = new MutationObserver(function(mutations) {
    for (var i = 0; i < mutations.length; i++) {
      var added = mutations[i].addedNodes;
      if (!added) continue;
      for (var j = 0; j < added.length; j++) walk(added[j]);
    }
  });

  function start() {
    scanDocument();
    if (document.body) {
      observer.observe(document.body, { childList: true, subtree: true });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
  window.addEventListener("load", scanDocument);
})();
