"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");

function element() {
  return {
    nodeType: 1,
    childNodes: [],
    textContent: "",
    attributes: {},
    matches: () => false,
    hasAttribute: () => false,
    getAttribute(name) { return this.attributes[name] ?? null; },
    setAttribute(name, value) { this.attributes[name] = value; },
    addEventListener() {},
  };
}

function browserContext(storedLanguage) {
  const values = new Map();
  if (storedLanguage !== undefined) values.set("med-audit-language", storedLanguage);
  const toggle = element();
  const body = element();
  const documentElement = {lang: ""};
  const document = {
    body,
    documentElement,
    title: "",
    getElementById(id) { return id === "managementLanguage" || id === "languageToggle" ? toggle : null; },
  };
  const context = {
    console,
    document,
    localStorage: {
      getItem(key) { return values.has(key) ? values.get(key) : null; },
      setItem(key, value) { values.set(key, value); },
    },
    MutationObserver: class { observe() {} },
    Node: {TEXT_NODE: 3, ELEMENT_NODE: 1},
    window: {},
    URL,
    Date,
    setTimeout,
    clearTimeout,
  };
  context.window = context;
  return {context: vm.createContext(context), document, toggle, values};
}

function runWorkbench(storedLanguage) {
  const browser = browserContext(storedLanguage);
  const source = fs.readFileSync(path.join(root, "web", "app.js"), "utf8")
    .split("\ninitLanguage();")[0];
  vm.runInContext(source, browser.context);
  vm.runInContext("initLanguage();", browser.context);
  return browser;
}

function runManagement(storedLanguage) {
  const browser = browserContext(storedLanguage);
  vm.runInContext(fs.readFileSync(path.join(root, "web", "management-i18n.js"), "utf8"), browser.context);
  return browser;
}

test("workbench defaults to English without a saved preference", () => {
  const {document, toggle} = runWorkbench(undefined);
  assert.equal(document.documentElement.lang, "en");
  assert.equal(document.title, "Medical Insurance Audit · Local Demo");
  assert.equal(toggle.textContent, "中文");
});

test("management pages default to English without a saved preference", () => {
  const {document, toggle} = runManagement(undefined);
  assert.equal(document.documentElement.lang, "en");
  assert.equal(toggle.textContent, "中文");
});

test("initial HTML matches the English default before scripts run", () => {
  for (const file of ["index.html", "login.html", "settings.html", "mcp-tokens.html"]) {
    const html = fs.readFileSync(path.join(root, "web", file), "utf8");
    assert.match(html, /<html lang="en">/, file);
    assert.match(html, /id="(?:languageToggle|managementLanguage)"[^>]*aria-label="切换至中文"[^>]*>中文<\/button>/, file);
  }
  assert.match(
    fs.readFileSync(path.join(root, "web", "index.html"), "utf8"),
    /<title>Medical Insurance Audit · Local Demo<\/title>/,
  );
});

test("an explicit Chinese preference remains Chinese on all pages", () => {
  const workbench = runWorkbench("zh");
  const management = runManagement("zh");
  assert.equal(workbench.document.documentElement.lang, "zh-CN");
  assert.equal(workbench.toggle.textContent, "English");
  assert.equal(management.document.documentElement.lang, "zh-CN");
  assert.equal(management.toggle.textContent, "English");
});
