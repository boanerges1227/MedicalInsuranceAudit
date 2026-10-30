'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {classifyEventStatus, filterEvents, countEventGroups} = require('../web/flow.js');

test('按真实状态分组，未知与历史状态单独保留', () => {
  for (const state of ['QUEUED','RUNNING','PROCESSING']) assert.equal(classifyEventStatus(state),'active');
  assert.equal(classifyEventStatus('SUCCEEDED'),'succeeded');
  for (const state of ['FAILED','AUDIT_FAILED']) assert.equal(classifyEventStatus(state),'failed');
  for (const state of ['SUPERSEDED','HISTORY_UNAVAILABLE','UNKNOWN','',undefined]) assert.equal(classifyEventStatus(state),'other');
});
test('分类和事件或就诊 ID 搜索可组合，原数据不变', () => {
  const events=[{eventId:'EVENT-a',encounterId:'Encounter-1',status:'FAILED'},{eventId:'event-b',encounterId:'encounter-2',status:'QUEUED'},{eventId:'old',status:'UNKNOWN'}];
  assert.deepEqual(countEventGroups(events),{all:3,active:1,succeeded:0,failed:1,other:1});
  assert.deepEqual(filterEvents(events,'failed',' ENCOUNTER-1 '),[events[0]]);
  assert.deepEqual(filterEvents(events,'all','EVENT-B'),[events[1]]);
  assert.deepEqual(filterEvents(events,'other',''),[events[2]]);
  assert.equal(events.length,3);
});
