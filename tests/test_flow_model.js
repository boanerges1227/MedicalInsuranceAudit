'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {buildFlow} = require('../web/flow.js');
test('preserves recorded order and event identity', () => {
  const graph=buildFlow({eventId:'one',status:'SUCCEEDED',stages:[{name:'接收',node:'A',at:'1'},{name:'审核',node:'B',at:'2'}]});
  assert.equal(graph.eventId,'one'); assert.deepEqual(graph.steps.map(x=>x.name),['接收','审核']); assert.equal(graph.steps[1].at,'2');
});
test('old or missing history is explicit and never borrows stages', () => {
  const graph=buildFlow({eventId:'old',status:'SUPERSEDED',historyAvailable:false,stages:[]});
  assert.equal(graph.unavailable,true); assert.deepEqual(graph.steps,[]);
});
test('failure is separate from recorded completed stages', () => {
  const graph=buildFlow({eventId:'failed',status:'FAILED',lastError:'FAIL',stages:[{name:'接收'}]});
  assert.equal(graph.failed,true); assert.equal(graph.error,'FAIL'); assert.equal(graph.steps.length,1);
});
test('queued retry exposes mixed stage history before another attempt begins', () => {
  const graph=buildFlow({eventId:'retry',status:'QUEUED',attempts:1,stages:[{name:'接收'}]});
  assert.equal(graph.mixedAttempts,true);
});
test('first queued attempt does not claim retry history', () => {
  assert.equal(buildFlow({eventId:'first',status:'QUEUED',attempts:0,stages:[{name:'接收'}]}).mixedAttempts,false);
});
test('missing stage history does not hide an actual failure', () => {
  const {renderFlow}=require('../web/flow.js');
  class Element { constructor(){this.children=[];this.textContent='';this.classList={remove(){},add(){}};} append(...items){this.children.push(...items);} replaceChildren(...items){this.children=items;} setAttribute(){} }
  global.document={createElement:()=>new Element()};
  const container=new Element();
  renderFlow(container,{eventId:'x',status:'FAILED',lastError:'AUDIT_FAILED',stages:[]},x=>x);
  assert.ok(container.children.some(x=>x.textContent.includes('AUDIT_FAILED')));
  assert.ok(container.children.some(x=>x.textContent.includes('不可用')));
  delete global.document;
});
test('failed audit is not presented as no findings', () => {
  const {emptyRiskMessage}=require('../web/flow.js');
  assert.match(emptyRiskMessage('AUDIT_FAILED'), /失败/);
  assert.match(emptyRiskMessage('PENDING_REVIEW'), /未命中/);
});
