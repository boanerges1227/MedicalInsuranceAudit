/* Build and replay recorded event stages without inferring unrecorded message transitions. */
(function (root) {
  'use strict';
  const timers = new WeakMap();

  /** Convert one event's recorded stages into a read-only flow model. */
  function buildFlow(event) {
    const stages = Array.isArray(event.stages) ? event.stages : [];
    return {eventId: String(event.eventId || ''), steps: stages.map(stage => ({name: String(stage.name || ''), node: String(stage.node || ''), at: String(stage.at || '')})), unavailable: event.historyAvailable === false || stages.length === 0, failed: ['FAILED','AUDIT_FAILED'].includes(event.status), mixedAttempts: Number(event.attempts)>1 || (event.status==='QUEUED' && Number(event.attempts)>0), error: String(event.lastError || '')};
  }

  /** Render recorded stages through text nodes; playback speed does not represent actual elapsed time. */
  function renderFlow(container, event, formatTime) {
    for (const timer of timers.get(container) || []) clearTimeout(timer);
    const graph = buildFlow(event); container.replaceChildren();
    const line = document.createElement('p'); line.className = 'flow-caption'; line.textContent = '业务阶段回放 · 动画速度不代表真实耗时'; container.append(line);
    if (graph.mixedAttempts) { const warning=document.createElement('p'); warning.className='flow-caption'; warning.textContent='阶段记录可能包含多次尝试，未按重试次数区分。'; container.append(warning); }
    if (graph.unavailable) {
      const empty=document.createElement('p'); empty.className='empty'; empty.textContent='该事件的阶段记录不可用。'; container.append(empty);
      if (graph.failed) { const failure=document.createElement('p'); failure.className='flow-failure'; failure.textContent='事件处理失败'+(graph.error ? '：'+graph.error : ''); container.append(failure); }
      return;
    }
    const track=document.createElement('div'); track.className='flow-track';
    const cards=[];
    graph.steps.forEach((step, index) => {
      if (index) { const arrow=document.createElement('span'); arrow.className='flow-arrow'; arrow.textContent='→'; arrow.setAttribute('aria-hidden','true'); track.append(arrow); }
      const card=document.createElement('div'); card.className='flow-node';
      const order=document.createElement('span'); order.className='flow-order'; order.textContent=String(index+1).padStart(2,'0');
      const name=document.createElement('strong'); name.textContent=step.name;
      const detail=document.createElement('small'); detail.textContent=[step.node,step.at ? formatTime(step.at) : ''].filter(Boolean).join(' · ');
      card.append(order,name,detail); track.append(card); cards.push(card);
    });
    container.append(track);
    if (graph.failed) { const failure=document.createElement('p'); failure.className='flow-failure'; failure.textContent='事件处理失败'+(graph.error ? '：'+graph.error : ''); container.append(failure); }
    const replay=document.createElement('button'); replay.type='button'; replay.className='secondary flow-replay'; replay.textContent='重新回放';
    /** Highlight stages in recorded order without inferring waits or missing nodes. */
    const play=() => {
      for (const timer of timers.get(container) || []) clearTimeout(timer);
      cards.forEach(card => card.classList.remove('flow-active'));
      const queue=cards.map((card,index)=>setTimeout(()=>{ cards.forEach(c=>c.classList.remove('flow-active')); card.classList.add('flow-active'); },index*500));
      queue.push(setTimeout(()=>cards.forEach(card=>card.classList.remove('flow-active')),cards.length*500+500)); timers.set(container,queue);
    };
    replay.addEventListener('click',play); container.append(replay); play();
  }
  /** Distinguish failures, processing, and completed searches without matches; never describe failure as no findings. */
  function emptyRiskMessage(status) {
    if (status === 'AUDIT_FAILED') return '审核失败，结果不可用，请查看事件监控。';
    if (status === 'PROCESSING') return '审核排队或处理中，请刷新详情查看结果。';
    return '未命中本地演示知识条目。';
  }
  /** Build the flow only from this task's recorded stages and tool traces without fabricating calls for legacy data. */
  function buildAgentFlow(data) {
    const job=data.job || {}, trace=Array.isArray(data.trace)?data.trace:[], steps=[];
    if (job.runId) steps.push({kind:'QUEUED',at:job.createdAt || ''});
    if (job.startedAt) steps.push({kind:'RUNNING',at:job.startedAt});
    for (const entry of trace) if (['MODEL_STARTED','CASE_EVIDENCE','POLICY_EVIDENCE','OUTPUT_VALIDATED'].includes(entry.kind)) steps.push({kind:entry.kind,at:entry.at || ''});
    if (['SUCCEEDED','FAILED'].includes(job.status)) steps.push({kind:job.status,at:job.finishedAt || ''});
    return {steps, status:job.status || '', error:job.result?.error || '', detailsUnavailable:!!job.runId && !trace.length && ['SUCCEEDED','FAILED'].includes(job.status)};
  }
  /** Reject status updates for a different event, version, or investigation task. */
  function matchesAgentRun(expected,data) {
    return data.eventId===expected.eventId && data.caseVersion===expected.version && Number(data.job?.runId)===Number(expected.runId);
  }
  /** Render recorded investigation stages as a desktop flow and animate the active node. */
  function renderAgentFlow(container,data,formatTime,errorText) {
    const graph=buildAgentFlow(data),labels={QUEUED:'调查已排队',RUNNING:'工作进程已领取',MODEL_STARTED:'开始模型调用',CASE_EVIDENCE:'病例证据工具已返回',POLICY_EVIDENCE:'政策证据工具已返回',OUTPUT_VALIDATED:'输出与引用校验通过',SUCCEEDED:'调查完成',FAILED:'调查失败'};
    const components={QUEUED:'HD.AgentRequest.Reserve',RUNNING:'AgentReview · HD.AgentOperation',MODEL_STARTED:'%AI.Agent.Chat',CASE_EVIDENCE:'get_case_evidence · HD.AgentTools.Summary',POLICY_EVIDENCE:'get_policy_evidence · HD.AgentTools.Policy',OUTPUT_VALIDATED:'HD.Agent.Validate',SUCCEEDED:'HD.AgentRequest.Finish',FAILED:'HD.AgentRequest.Finish'};
    container.replaceChildren();
    const note=document.createElement('p');note.className='flow-caption';note.textContent='仅显示本次调查已记录的状态和工具调用。';container.append(note);
    if(!graph.steps.length) { const empty=document.createElement('p');empty.className='empty';empty.textContent='正在提交调查，等待任务编号…';container.append(empty);return; }
    const track=document.createElement('div');track.className='flow-track agent-flow-track';
    graph.steps.forEach((step,index)=>{
      if(index){const arrow=document.createElement('span');arrow.className='flow-arrow';arrow.textContent='→';arrow.setAttribute('aria-hidden','true');track.append(arrow);}
      const card=document.createElement('div');card.className='flow-node';
      if(index===graph.steps.length-1 && ['QUEUED','RUNNING'].includes(graph.status)) card.classList.add('agent-flow-active');
      if(step.kind==='FAILED') card.classList.add('agent-flow-failed');
      const number=document.createElement('span');number.className='flow-order';number.textContent=String(index+1).padStart(2,'0');
      const title=document.createElement('strong');title.textContent=labels[step.kind];
      const at=document.createElement('small');at.textContent=components[step.kind]+' · '+(step.at?formatTime(step.at):'时间未记录');
      card.append(number,title,at);track.append(card);
    });
    container.append(track);
    if(graph.detailsUnavailable){const missing=document.createElement('p');missing.className='hint';missing.textContent='没有可用的工具调用明细；历史任务可能未记录。';container.append(missing);}
    if(graph.status==='RUNNING'){const pending=document.createElement('p');pending.className='hint';pending.textContent='调查进行中，等待新的实际调用记录…';container.append(pending);}
    if(graph.error){const err=document.createElement('p');err.className='flow-failure';err.textContent='调查未完成：'+errorText(graph.error);container.append(err);}
  }
  /** Group by recorded processing status; missing or unrecognized statuses stay in the other group. */
  function classifyEventStatus(status) {
    if (['QUEUED','RUNNING','PROCESSING'].includes(status)) return 'active';
    if (status === 'SUCCEEDED') return 'succeeded';
    if (['FAILED','AUDIT_FAILED'].includes(status)) return 'failed';
    return 'other';
  }
  /** Filter by status combined with event or encounter id, without modifying server-returned data. */
  function filterEvents(events, group, query) {
    const key=String(query || '').trim().toLowerCase();
    return events.filter(event => (group === 'all' || classifyEventStatus(event.status) === group) && (!key || String(event.eventId || event.id || '').toLowerCase().includes(key) || String(event.encounterId || '').toLowerCase().includes(key)));
  }
  /** Category counts come from currently loaded records and do not represent real-time service throughput. */
  function countEventGroups(events) {
    const counts={all:events.length,active:0,succeeded:0,failed:0,other:0};
    for (const event of events) counts[classifyEventStatus(event.status)]++;
    return counts;
  }
  if (typeof module !== 'undefined' && module.exports) module.exports={buildFlow,renderFlow,emptyRiskMessage,buildAgentFlow,matchesAgentRun,renderAgentFlow,classifyEventStatus,filterEvents,countEventGroups};
  if (root) root.medFlow={buildFlow,renderFlow,emptyRiskMessage,buildAgentFlow,matchesAgentRun,renderAgentFlow,classifyEventStatus,filterEvents,countEventGroups};
})(typeof window !== 'undefined' ? window : null);
