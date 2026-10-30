'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {buildAgentFlow, matchesAgentRun}=require('../web/flow.js');
test('queued task does not invent model or tool calls',()=>{
 const flow=buildAgentFlow({job:{runId:5,status:'QUEUED',createdAt:'1'},trace:[]});
 assert.deepEqual(flow.steps.map(x=>x.kind),['QUEUED']);
});
test('uses actual trace order and reports terminal failure',()=>{
 const flow=buildAgentFlow({job:{runId:8,status:'FAILED',createdAt:'1',startedAt:'2',finishedAt:'4',result:{error:'ERR'}},trace:[{kind:'POLICY_EVIDENCE',at:'3'},{kind:'CASE_EVIDENCE',at:'3.1'}]});
 assert.deepEqual(flow.steps.map(x=>x.kind),['QUEUED','RUNNING','POLICY_EVIDENCE','CASE_EVIDENCE','FAILED']);
 assert.equal(flow.error,'ERR');
});
test('status response cannot cross event, version or run identity',()=>{
 const expected={eventId:'e1',version:2,runId:7};
 assert.equal(matchesAgentRun(expected,{eventId:'e1',caseVersion:2,job:{runId:7}}),true);
 assert.equal(matchesAgentRun(expected,{eventId:'e2',caseVersion:2,job:{runId:7}}),false);
 assert.equal(matchesAgentRun(expected,{eventId:'e1',caseVersion:3,job:{runId:7}}),false);
 assert.equal(matchesAgentRun(expected,{eventId:'e1',caseVersion:2,job:{runId:8}}),false);
});
