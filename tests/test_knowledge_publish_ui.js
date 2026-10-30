"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "web", "index.html"), "utf8");
const app = fs.readFileSync(path.join(root, "web", "app.js"), "utf8");

function loadPureHelpers() {
  const context = vm.createContext({window: {}});
  const match = app.match(/\/\* KNOWLEDGE_PUBLISH_HELPERS_START \*\/([\s\S]*?)\/\* KNOWLEDGE_PUBLISH_HELPERS_END \*\//);
  assert.ok(match, "knowledge publish helper block is missing");
  vm.runInContext(match[1], context);
  return context.window.medKnowledgePublishUI;
}

test("vector library contains batch controls and a metadata confirmation dialog", () => {
  for (const id of [
    "uploadPublishBatch", "uploadPublishSelection", "knowledgePublishDialog", "knowledgePublishForm",
    "publishSourceId", "publishTitle", "publishRegion", "publishSourceUrl", "publishPublicationDate",
    "publishEffectiveDate", "publishEffectiveStatus", "publishExceptionConditions", "publishNeedsReview",
    "publishConfirmed", "knowledgePublishSave", "knowledgePublishNow", "knowledgePublishExcerpt",
  ]) assert.match(html, new RegExp(`id="${id}"`), id);
});

test("only server READY jobs can enter batch publishing", () => {
  const helpers = loadPureHelpers();
  assert.equal(helpers.canBatchPublish({state: "SUCCEEDED", publication: {state: "READY"}}), true);
  assert.equal(helpers.canBatchPublish({state: "SUCCEEDED", publication: {state: "REVIEW_REQUIRED"}}), false);
  assert.equal(helpers.canBatchPublish({state: "FAILED", publication: {state: "READY"}}), false);
  assert.equal(helpers.canBatchPublish({state: "SUCCEEDED", publication: {state: "PUBLISHED"}}), false);
});

test("publication status labels distinguish review, ready, published and withdrawn", () => {
  const helpers = loadPureHelpers();
  assert.equal(helpers.publicationLabel("REVIEW_REQUIRED"), "待核实");
  assert.equal(helpers.publicationLabel("READY"), "可发布");
  assert.equal(helpers.publicationLabel("PUBLISHED"), "已发布");
  assert.equal(helpers.publicationLabel("WITHDRAWN"), "已撤回");
});

test("UI uses text-safe form assignments and exposes publish and withdraw actions", () => {
  assert.match(app, /function openKnowledgePublish\(/);
  assert.match(app, /\.value\s*=\s*metadata\./);
  assert.match(app, /function publishKnowledge\(/);
  assert.match(app, /function publishSelectedKnowledge\(/);
  assert.match(app, /function withdrawKnowledge\(/);
  assert.doesNotMatch(app, /knowledgePublishExcerpt[^\n]*innerHTML/);
});

test("English translations cover the new publication workflow", () => {
  for (const phrase of ["核实并发布", "批量发布", "发布到知识依据库", "撤回发布", "已核对原文依据、地区、日期和例外条件"])
    assert.match(app, new RegExp(`"${phrase}"\\s*:`), phrase);
});
