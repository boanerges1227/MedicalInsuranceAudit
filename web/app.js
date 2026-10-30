"use strict";

const $ = (id) => document.getElementById(id);
let selectedCase = null;
// Save the detail origin so the back link returns to the tab the user opened the case from.
let lastAuditPage = "cases";
let detailRequest = 0;
let agentPollTimer = null, agentRequestBusy = false, agentStatusSeq = 0;
let cases = [];
let caseDetails = [];
const pageState = {cases: 1, events: 1, policies: 1, uploads: 1, fhirFiles: 1, workflow: 1, workflowDispatch: 1};
let workflowTasks = [], workflowDispatchErrors = [], workflowRequest = 0, currentWorkflowUser = "", workflowTab = "AVAILABLE";
const workflowBusy = new Set(), workflowDispatchBusy = new Set();
const pageSize = 10;
let policyRequest = 0;
let eventItems = [], eventGroup = "all", eventRequest = 0;
let flowPollTimer = null, flowPollSeq = 0, detailFlowPollTimer = null;
let agentFlowTimer = null, agentFlowSeq = 0;
const eventStatusLabels = {QUEUED: "排队中", RUNNING: "处理中", PROCESSING: "处理中", AUDIT_FAILED: "审核失败", SUCCEEDED: "处理成功", FAILED: "处理失败", SUPERSEDED: "已被新事件取代", HISTORY_UNAVAILABLE: "历史状态不可用"};
const statusLabels = {PROCESSING: "处理中", AUDIT_FAILED: "审核失败", PENDING_REVIEW: "待复核", NEEDS_CHECK: "待核查", CONFIRMED: "已确认", DISMISSED: "已排除", PENDING: "待复核"};

/** Write dynamic content through text nodes so clinical or policy text cannot execute as HTML. */
function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== null) node.textContent = String(text);
  if (className) node.className = className;
  return node;
}
/** Paginate loaded data and clamp the current page when the result set shrinks. */
function paginate(name, items, draw) {
  const pages = Math.max(1, Math.ceil(items.length / pageSize));
  pageState[name] = Math.min(Math.max(1, pageState[name]), pages);
  const current = pageState[name], container = $(`${name}Pager`);
  container.replaceChildren();
  if (!items.length) { container.hidden = true; return []; }
  container.hidden = false;
  const info = el("span", `共 ${items.length} 条 · 第 ${current} / ${pages} 页`, "pager-info");
  const previous = el("button", "上一页", "secondary"), next = el("button", "下一页", "secondary");
  previous.disabled = current === 1; next.disabled = current === pages;
  previous.addEventListener("click", () => { pageState[name]--; draw(); });
  next.addEventListener("click", () => { pageState[name]++; draw(); });
  container.append(info, previous, next);
  return items.slice((current - 1) * pageSize, current * pageSize);
}
/** Convert internal IRIS timestamps to browser local time and display other formats unchanged. */
function formatIrisTime(value) {
  if (!value) return "待补充";
  const parts = String(value).split(",");
  if (parts.length !== 2 || parts.some((part) => !Number.isFinite(Number(part)))) return String(value);
  return new Date(Date.UTC(1840, 11, 31) + Number(parts[0]) * 86400000 + Number(parts[1]) * 1000).toLocaleString("zh-CN", {hour12: false});
}
/** Use same-origin endpoints and the local demo header for all requests while preserving server errors. */
async function api(path, options = {}) {
  const response = await fetch(path, {...options, headers: {"X-Med-Audit-Demo": "local-demo", ...(options.headers || {})}});
  let data;
  try { data = await response.json(); } catch (_) { throw new Error(`接口响应不可用（HTTP ${response.status}）`); }
  if (response.status === 401) { location.replace("/med-audit/login"); throw new Error("登录已过期，请重新登录。"); }
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}
/** Allow only safe HTTP(S) links to official sources. */
function sourceLink(url) {
  try {
    const parsed = new URL(url);
    if (!["http:", "https:"].includes(parsed.protocol)) return null;
    const link = el("a", "查看来源原文 ↗"); link.href = parsed.href; link.target = "_blank"; link.rel = "noopener noreferrer"; return link;
  } catch (_) { return null; }
}
/** Check that the URL still identifies the selected case before submitting or populating data. */
function isCurrentDetail(id) { return location.hash === `#detail/${encodeURIComponent(id)}`; }
/** Navigate with the URL hash to support browser history and direct case links. */
async function route() {
  const [pageName, encodedId] = location.hash.slice(1).split("/");
  ++detailRequest;
  if ($("agentFlowDialog").open) $("agentFlowDialog").close();
  clearTimeout(detailFlowPollTimer);
  clearTimeout(agentPollTimer); ++agentStatusSeq; $("agentInvestigate").disabled = true;
  selectedCase = null;
  $("agentFlowOpen").hidden=true; delete $("agentFlowOpen").dataset.runId;
  $("reviewButton").disabled = true;
  const page = ["dashboard", "overview", "cases", "case-list", "detail", "policies", "uploads", "events", "fhir", "fhir-files", "production", "mcp", "mcp-tokens", "ai-settings"].includes(pageName) ? pageName : "dashboard";
  document.body.classList.toggle("production-view", page === "production");
  for (const section of document.querySelectorAll(".page")) section.hidden = section.id !== `page-${page}`;
  for (const link of document.querySelectorAll("nav a")) link.classList.toggle("active", link.dataset.page === ((page === "detail" || page === "case-list") ? "cases" : page === "mcp-tokens" ? "mcp" : page));
  // Keep the current page title in the top bar; show descriptions and actions in the content area.
  $("pageTitle").textContent = {dashboard: "工作台", overview: "运行大屏", cases: "审核任务", "case-list": "审核任务", detail: "任务详情", policies: "知识依据库", uploads: "文件向量库", events: "事件监控", fhir: "FHIR 测试入口", "fhir-files": "FHIR 文件接入", production: "IRIS Production", mcp: "MCP 管理", "mcp-tokens": "MCP 管理", "ai-settings": "AI 设置"}[page];
  // The two tabs share the module title and sidebar entry; switching preserves browser history.
  const isAudit = page === "cases" || page === "case-list";
  $("auditModule").hidden = !isAudit;
  if (isAudit) lastAuditPage = page;
  for (const [id, selected] of [["auditTasksTab",page === "cases"],["auditCasesTab",page === "case-list"]]) { const tab=$(id); tab.setAttribute("aria-selected",String(selected)); tab.tabIndex=selected?0:-1; }
  $("auditDetailBack").href = `#${lastAuditPage}`;
  $("auditDetailBack").textContent = lastAuditPage === "case-list" ? "← 返回审核案例" : "← 返回审核任务";
  // Share one module title and tabs across both MCP routes while preserving URLs and browser history.
  const isMcp = page === "mcp" || page === "mcp-tokens";
  $("mcpModule").hidden = !isMcp;
  for (const [id, selected] of [["mcpServiceTab",page === "mcp"],["mcpTokensTab",page === "mcp-tokens"]]) { const tab=$(id);tab.setAttribute("aria-selected",String(selected));tab.tabIndex=selected?0:-1; }
  const isAdmin = page === "mcp-tokens" || page === "ai-settings";
  if (isAdmin) await window.medAuditAdmin.open(page); else window.medAuditAdmin?.leave();
  if (page === "detail" && encodedId) {
    try { await showCase(decodeURIComponent(encodedId)); } catch (error) { if (isCurrentDetail(decodeURIComponent(encodedId))) $("risks").textContent = `案例加载失败：${error.message}`; }
  }
  if (page === "fhir-files") { pageState.fhirFiles = 1; await loadFHIRFiles(); }
  if (page === "uploads") { pageState.uploads = 1; await loadUploads(); }
  if (page === "cases") { pageState.workflow = 1; pageState.workflowDispatch = 1; await loadWorkflowTasks(); }
  if (page === "case-list") { await refreshCases(); }
  if (page === "dashboard") await loadDashboardEvents();
  if (page === "events") await loadEvents();
  if (page === "overview") await loadOverview();
  if (page === "mcp") { mcpLogCursors = [""]; mcpLogPage = 0; await Promise.all([loadMCPStatus(), loadMCPLogs()]); }
  // Demo only: the server returns the fixed native portal URL with the demo account so the embedded page opens without a second login.
  if (page === "production" && !$("productionFrame").getAttribute("src")) {
    try {
      // Get the fixed local Production URL from the authenticated endpoint; clients cannot choose the target.
      const target = await api("api/production-target");
      if (location.hash !== "#production") return;
      $("productionOpen").href = target.url; $("productionFrame").src = target.url;
      $("productionStatus").textContent = "";
    } catch (error) { $("productionStatus").textContent = "Production 管理入口暂不可用，请检查 IRIS 服务。"; }
  }
}
/** Compute statistics from available API data; failed requests and historical observations do not establish live health. */
async function loadOverview() {
  const summary = $("overviewSummary"), eventsBox = $("overviewEvents"), services = $("overviewServices");
  summary.replaceChildren(); eventsBox.textContent = "加载中…"; services.textContent = "加载中…"; $("overviewNote").textContent = "";
  const results = await Promise.allSettled([api("api/health"), api("api/cases"), api("api/events"), api("api/mcp-status"), api("api/agent-summary")]);
  if (location.hash !== "#overview") return;
  const health = results[0].status === "fulfilled" ? results[0].value : null;
  const items = results[1].status === "fulfilled" ? (results[1].value.cases || []) : null;
  const events = results[2].status === "fulfilled" ? (results[2].value.events || []) : null;
  const count = (array, fn) => array ? array.filter(fn).length : "不可用";
  for (const [label, value, caption] of [["合成就诊", items ? items.length : "不可用", "当前案例总数"], ["审核处理中", count(items, c => c.status === "PROCESSING"), "病例状态"], ["待人工复核", count(items, c => ["PENDING_REVIEW", "NEEDS_CHECK"].includes(c.status)), "病例状态"], ["审核失败", count(items, c => c.status === "AUDIT_FAILED"), "病例状态"], ["待处理事件", count(events, e => ["QUEUED", "RUNNING"].includes(e.status)), "事件台账"], ["失败事件", count(events, e => e.status === "FAILED"), "事件台账"]]) {
    const card = el("div", undefined, "overview-card"); card.append(el("span", label), el("strong", value), el("small", caption)); summary.append(card);
  }
  eventsBox.replaceChildren();
  if (!events) eventsBox.append(el("p", "事件监控数据不可用。", "hint"));
  else for (const [status, label] of [["QUEUED", "排队中"], ["RUNNING", "处理中"], ["SUCCEEDED", "处理成功"], ["FAILED", "处理失败"], ["SUPERSEDED", "已被新事件取代"]]) {
    const n = events.filter(e => e.status === status).length, row = el("div", undefined, "overview-row"), bar = el("progress", undefined, "overview-bar");
    bar.max = Math.max(events.length, 1); bar.value = n; row.append(el("span", label), bar, el("strong", n)); eventsBox.append(row);
  }
  services.replaceChildren();
  services.append(el("p", health ? (health.productionRunning ? "IRIS Production：运行中" : "IRIS Production：未运行") : "IRIS Production：状态不可用"));
  const agent=results[4].status === "fulfilled" ? results[4].value : null;
  services.append(el("p", agent ? `AI 历史调查：${agent.total} 次，模型已启动 ${agent.modelStarted} 次，成功 ${agent.succeeded} / 失败 ${agent.failed}。` : "AI 历史调查统计不可用。"));
  services.append(el("p", agent && agent.usageRecorded ? `已记录用量（${agent.usageRecorded} 次）：输入 ${agent.inputTokens} / 输出 ${agent.outputTokens} Token。` : "Token 用量无可用记录。"));
  services.append(el("p", agent && agent.durationRecorded ? `已记录平均耗时（${agent.durationRecorded} 次）：${Number(agent.averageSeconds).toFixed(2)} 秒。` : "调查耗时无可用记录。"));
  services.append(el("p", "统计基于历史任务；当前模型连通性未检测。"));
  const mcp = results[3].status === "fulfilled" ? results[3].value : null;
  services.append(el("p", mcp ? `MCP 历史调用：${mcp.observedCalls}；服务${mcp.serviceEnabled ? "已开启" : "已关闭"}，网关${mcp.gatewayReachability === "REACHABLE" ? "可连通" : "不可连通"}。` : "MCP 服务：状态不可用。"));
  $("overviewNote").textContent = `采样时间：${new Date().toLocaleString("zh-CN", {hour12:false})}；统计的是接口当前返回的合成数据。`;
}
let mcpLogCursors = [""], mcpLogPage = 0, mcpNextCursor = "", mcpBusy = false;
/** Read the actual service switch and gateway HTTP reachability; historical calls do not prove current health. */
async function loadMCPStatus() {
  const box = $("mcpDetails"); box.textContent = "加载中…";
  $("mcpEnable").disabled = true; $("mcpDisable").disabled = true;
  try {
    const data = await api("api/mcp-status"); box.replaceChildren();
    for (const [label,value] of [["服务访问",data.serviceEnabled ? "已开启" : "已关闭"],["网关连通性",data.gatewayReachability === "REACHABLE" ? "可连通" : "不可连通"],["历史调用",String(data.observedCalls)],["成功 / 失败",`${data.observedSucceeded} / ${data.observedFailed}`]]) { const card=el("div",undefined,"mcp-stat");card.append(el("span",label),el("strong",value));box.append(card); }
    $("mcpEnable").disabled = mcpBusy || Boolean(data.serviceEnabled);
    $("mcpDisable").disabled = mcpBusy || !data.serviceEnabled;
  } catch (error) { box.textContent = `MCP 数据不可用：${error.message}`; }
}
/** Change tool access and reread the actual state after the response. */
async function setMCPService(enabled) {
  if (mcpBusy) return;
  if (!enabled && !window.confirm(interfaceLanguage === "en" ? "Disable MCP access for new calls?" : "关闭后新的 MCP 调用将被拒绝，确定关闭吗？")) return;
  mcpBusy=true; $("mcpEnable").disabled=true; $("mcpDisable").disabled=true; $("mcpControlMessage").textContent="正在更新服务状态…";
  try { await api("api/mcp-control",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({enabled})}); $("mcpControlMessage").textContent=enabled ? "服务已开启。" : "服务已关闭。"; }
  catch (error) { $("mcpControlMessage").textContent=`服务操作失败：${error.message}`; }
  finally { mcpBusy=false; await loadMCPStatus(); }
}
/** Read tool audit logs with cursors instead of loading all historical records at once. */
async function loadMCPLogs() {
  const box=$("mcpLogs"), page=mcpLogPage, cursor=mcpLogCursors[page];box.textContent="加载中…";$("mcpLogPrev").disabled=true;$("mcpLogNext").disabled=true;
  try {
    const data=await api("api/mcp-logs"+(cursor ? `?before=${encodeURIComponent(cursor)}` : "")); if(page!==mcpLogPage)return;
    box.replaceChildren();mcpNextCursor=data.nextBefore||"";
    if(!data.items.length)box.append(el("p","暂无调用记录。","empty"));
    for(const item of data.items){
      const row=el("div",undefined,"mcp-log-row"),time=item.occurredAtEpoch ? new Date(item.occurredAtEpoch*1000).toLocaleString() : "待补充";
      const outcome={ALLOWED:"成功",DENIED:"拒绝",FAILED:"失败"}[item.outcome]||item.outcome||"—";
      row.append(el("strong",item.tool||"—"),el("span",outcome,"status-chip"),el("span",time),el("span",`${item.durationMs ?? 0} ms`),el("small",`${item.actor||"—"} · ${item.caseId||"—"} · v${item.caseVersion||0}`));box.append(row);
    }
    $("mcpLogPage").textContent=`第 ${page+1} 页`;$("mcpLogPrev").disabled=page===0;$("mcpLogNext").disabled=!mcpNextCursor;
  } catch(error) { box.textContent=`调用日志不可用：${error.message}`; }
}
/** Compute statistics from case listings and details; explicitly mark incomplete reads. */
function renderStats() {
  const findings = caseDetails.flatMap((item) => item.risks || []);
  const counts = {pending: 0, handled: 0};
  for (const risk of findings) {
    const status = risk.findingState?.status || "PENDING";
    if (["CONFIRMED", "DISMISSED"].includes(status)) counts.handled++; else counts.pending++;
  }
  const box = $("stats"); box.replaceChildren();
  for (const [label, value, description] of [["合成案例", cases.length, "当前案例总数"], ["待处理疑点", counts.pending, "待复核或继续核查"], ["已处理疑点", counts.handled, "已确认或已排除"]]) {
    const card = el("div", undefined, "stat-card"); card.append(el("span", label), el("strong", value), el("small", description)); box.append(card);
  }
  $("statsNote").textContent = `统计时间：${new Date().toLocaleString("zh-CN", {hour12: false})}；范围：当前加载的合成案例，按疑点状态统计。${caseDetails.length < cases.length ? "部分案例详情不可用，疑点统计不完整。" : ""}`;
}
/** Create a list item linking to case details. */
function caseRow(item) {
  const row = el("a", undefined, "case-row"); row.href = `#detail/${encodeURIComponent(item.encounterId)}`;
  const title = el("div"); title.append(el("strong", item.encounterId), el("small", `演示案例 · ${item.riskCount ?? "待核"} 条疑点`));
  row.append(title, el("span", statusLabels[item.status] || item.status || "待核查", "status-chip"), el("span", "查看详情 →", "row-action")); return row;
}
/** Filter cases by selected status and encounter ID without inventing missing fields. */
function renderCases() {
  const query = $("caseQuery").value.trim().toLowerCase(), filter = $("caseFilter").value;
  const shown = cases.filter((item) => String(item.encounterId).toLowerCase().includes(query) && (!filter || item.status === filter));
  const page = paginate("cases", shown, renderCases);
  $("caseList").replaceChildren(...(page.length ? page.map(caseRow) : [el("p", "没有符合条件的案例。", "empty")]));
  $("recentCases").replaceChildren(...(cases.length ? cases.slice(0, 5).map(caseRow) : [el("p", "暂无案例，可在 FHIR 测试入口发送合成示例。", "empty")]));
}
/** Refresh cases and statistics details; individual failures do not block other case displays. */
async function refreshCases(preferredId) {
  const data = await api("api/cases"); $("app-error").hidden = true; cases = Array.isArray(data.cases) ? data.cases : [];
  const results = await Promise.allSettled(cases.map((item) => api(`api/cases/${encodeURIComponent(item.encounterId)}`)));
  caseDetails = results.filter((r) => r.status === "fulfilled").map((r) => r.value);
  renderCases(); renderStats();
  if (preferredId) { location.hash = `#detail/${encodeURIComponent(preferredId)}`; if (selectedCase?.encounterId === preferredId) await showCase(preferredId); }
}
/** Build an independently versioned human review form and history for one finding. */
function findingCard(risk) {
  const encounterId = selectedCase.encounterId, eventId = selectedCase.eventId;
  const card = el("article", undefined, "risk-card");
  const state = risk.findingState || {status: "PENDING", version: 0, history: []};
  const id = risk.id || risk.findingId || risk.knowledgeId;
  card.append(el("div", `演示规则 · ${risk.level || "待核"} · ${risk.knowledgeId || id || "来源待核"} / ${risk.knowledgeVersion || "版本待核"}`, "risk-meta"), el("h3", risk.title || "待核查疑点"), el("p", risk.explanation || ""), el("span", `${statusLabels[state.status] || state.status || "待复核"} · 版本 ${state.version ?? 0}`, "status-chip"));
  for (const evidence of risk.evidence || []) card.append(el("div", `${evidence.resource} · ${evidence.path} = ${evidence.value}`, "evidence"));
  if ((risk.pending || []).length) { card.append(el("strong", "待核实项")); const list = el("ul"); for (const text of risk.pending) list.append(el("li", text)); card.append(list); }
  const history = el("details"); history.append(el("summary", `处置历史（${(state.history || []).length}）`));
  for (const action of state.history || []) history.append(el("p", `${formatIrisTime(action.at || action.time || action.timestamp)} · ${action.reviewer || "待核"} · ${statusLabels[action.decision || action.status] || action.decision || action.status || "待核"} · ${action.reason || ""}`));
  card.append(history);
  card.append(el("p", "已创建任务的疑点请在审核任务页领取并完成，原有疑点复核入口不能替代任务。", "hint"));
  const form = el("form", undefined, "finding-form");
  const decision = el("select"); decision.setAttribute("aria-label", "疑点处理决定");
  for (const [value, label] of [["NEEDS_CHECK", "继续核查"], ["CONFIRMED", "确认风险"], ["DISMISSED", "排除风险"]]) { const option = el("option", label); option.value = value; decision.append(option); }
  const reviewer = el("input"); reviewer.value = currentWorkflowUser; reviewer.readOnly = true; reviewer.maxLength = 80; reviewer.placeholder = "复核人"; reviewer.setAttribute("aria-label", "复核人");
  const reason = el("input"); reason.maxLength = 500; reason.placeholder = "填写处理理由"; reason.setAttribute("aria-label", "处理理由");
  const button = el("button", "提交疑点复核"); const status = el("span", "", "form-status"); status.setAttribute("role", "status");
  form.append(decision, reviewer, reason, button, status); card.append(form);
  if (!id || !risk.findingState || selectedCase.status === "PROCESSING") { button.disabled = true; status.textContent = "疑点处置接口或状态尚不可用"; }
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    // Submit only for the case and event captured when the form was created, preventing stale forms from updating a new case.
    if (!isCurrentDetail(encounterId) || selectedCase?.encounterId !== encounterId || selectedCase?.eventId !== eventId) { status.textContent = "案例已切换，请重新打开后操作。"; return; }
    button.disabled = true; status.textContent = "提交中…";
    try {
      await api(`api/cases/${encodeURIComponent(encounterId)}/findings/${encodeURIComponent(id)}/review`, {method: "POST", headers: {"Content-Type": "application/json; charset=utf-8"}, body: JSON.stringify({eventId, version: state.version, decision: decision.value, reviewer: reviewer.value.trim(), reason: reason.value.trim()})});
      if (isCurrentDetail(encounterId)) await showCase(encounterId);
      await refreshCases();
    } catch (error) { status.textContent = `提交失败：${error.message}；如版本冲突，请刷新案例后重试。`; button.disabled = false; }
  });
  return card;
}
/** Show case stages, finding evidence, policy sources, and existing case-level reviews. */
async function showCase(id) {
  const request = ++detailRequest;
  let detail;
  try { detail = await api(`api/cases/${encodeURIComponent(id)}`); }
  catch (error) { if (request === detailRequest && isCurrentDetail(id)) throw error; return; }
  // Prevent earlier requests or departed detail pages from overwriting the current selection.
  if (request !== detailRequest || !isCurrentDetail(id)) return;
  selectedCase = detail;
  $("detailId").textContent = `就诊 ID：${selectedCase.encounterId}`;
  $("caseStatus").textContent = `${statusLabels[selectedCase.status] || selectedCase.status || "待核"} · v${selectedCase.version ?? "待核"}`;
  $("reviewButton").disabled = selectedCase.status === "PROCESSING";
  window.medFlow.renderFlow($("flow"), selectedCase, formatIrisTime);
  // Refresh stages from the same event ledger and redraw only on stage changes to preserve human review forms.
  clearTimeout(detailFlowPollTimer); let flowFingerprint="";
  const refreshDetailFlow=async () => {
    try {
      const data=await api("api/events"), event=(data.events||[]).find(item=>item.eventId===detail.eventId);
      if(!event || request!==detailRequest || !isCurrentDetail(id)) return;
      const fingerprint=JSON.stringify([event.status,event.attempts,event.lastError,event.stages,event.historyAvailable]);
      if(fingerprint!==flowFingerprint){window.medFlow.renderFlow($("flow"),event,formatIrisTime);flowFingerprint=fingerprint;}
      if(["QUEUED","RUNNING"].includes(event.status)) detailFlowPollTimer=setTimeout(refreshDetailFlow,2500);
      else if(detail.status==="PROCESSING" && ["SUCCEEDED","FAILED"].includes(event.status)) await showCase(id);
    } catch (_) { /* Retain the loaded stages; users can refresh the details manually. */ }
  };
  refreshDetailFlow();
  $("risks").replaceChildren(...((selectedCase.risks || []).length ? selectedCase.risks.map(findingCard) : [el("p", window.medFlow.emptyRiskMessage(selectedCase.status), "empty")]));
  const box = $("policyEvidence"); box.replaceChildren(); const retrieval = selectedCase.policyRetrieval;
  if (!retrieval) box.append(el("p", "该历史案例尚未执行演示依据检索。", "hint"));
  else {
    const labels = {FOUND: "已检索，待核实", NOT_APPLICABLE: "未触发", NO_MATCH: "未找到依据", UNAVAILABLE: "检索不可用"};
    box.append(el("p", `${labels[retrieval.status] || retrieval.status} · ${retrieval.notice || ""}`, "hint"));
    if (retrieval.status === "FOUND") box.append(el("p", "检索范围：合成演示库 · 手工构造的固定测试向量 · 相似度不代表政策适用性。", "hint"));
    for (const ref of retrieval.fhirEvidence || []) box.append(el("div", `关联医嘱：${ref.resource} · ${ref.path} = ${ref.value}`, "evidence"));
    for (const item of selectedCase.policyEvidence || []) {
      const card = el("article", undefined, "risk-card"); card.append(el("div", `待核实 · ${item.policyId || ""} / ${item.chunkId || ""}`, "risk-meta"), el("h3", item.title), el("p", item.excerpt), el("div", `来源：${item.sourcePath || "待核"} · 相似度 ${Number.isFinite(Number(item.score)) ? Number(item.score).toFixed(3) : "待核"}`, "evidence"), el("div", `适用范围：虚构演示（非真实政策） · 发布日期：${item.dates?.publication_date || "待核"} · 生效日期：${item.dates?.effective_date || "待核"}`, "evidence"));
      const link = sourceLink(item.policyUrl || item.sourceUrl); if (link) card.append(link); box.append(card);
    }
  }
  // Poll the server-bound event and version; stale page responses must not overwrite the current case.
  clearTimeout(agentPollTimer); $("agentInvestigate").disabled=true; $("agentActionStatus").textContent="";
  renderAgentResult(selectedCase.agentReview); loadAgentStatus(selectedCase.encounterId, selectedCase.eventId, selectedCase.version);
  $("reviewRecord").replaceChildren(); if (selectedCase.review) $("reviewRecord").append(el("strong", "最近一次案例复核"), el("p", `${selectedCase.review.reviewer} · ${selectedCase.review.decision} · ${selectedCase.review.reason}`));
}
/** Map fixed server error codes to actionable messages. */
function agentErrorText(code) {
  const messages={AGENT_INPUT_INVALID:"调查参数无效，请刷新案例。",STALE_CASE:"案例或事件已更新，请刷新后重试。",CASE_NOT_READY:"案例审核尚未完成，请稍后再试。",AGENT_ALREADY_RUNNING:"已有调查正在处理，请稍后再试。",AGENT_DAILY_LIMIT:"已达到今日调查次数上限。",AGENT_DISPATCH_FAILED:"调查派发失败，请查看服务状态。",MODEL_NOT_CONFIGURED:"模型尚未配置，请检查 AI 设置。",MODEL_CONFIG_BUSY:"模型配置正忙，请稍后再试。",MODEL_OR_TOOL_ERROR:"模型或证据工具调用失败，请核查配置。",AGENT_PROCESS_ERROR:"调查进程发生错误。"};
  return messages[code]||code||"待核查";
}

/** Display actual model results and citations without estimating costs when usage is missing. */
function renderAgentResult(result) {
  const box=$("agentReview");box.replaceChildren();
  if(!result){box.append(el("p","当前案例尚未运行 AI Hub 调查。","hint"));return;}
  box.append(el("p",`状态：${result.status||"待核"} · 模型：${result.model||"未配置"}`,"risk-meta"));
  if(result.status==="VALIDATED") {
    box.append(el("p",result.summary,"agent-output"),el("p",result.notice,"hint"));
    if(Array.isArray(result.evidenceIds))box.append(el("p",`证据引用：${result.evidenceIds.join("、")}`,"hint"));
  } else box.append(el("p",`调查未完成：${agentErrorText(result.error)}；请人工复核。`,"hint"));
  const usage=result.usage||{};
  if(Number.isFinite(usage.total_prompt_tokens)&&Number.isFinite(usage.total_completion_tokens))box.append(el("p",`输入 / 输出 Token：${usage.total_prompt_tokens} / ${usage.total_completion_tokens} · 耗时：${result.elapsedSeconds ?? "—"} s`,"hint"));
  if(result.modelStarted)box.append(el("p","费用未计算，请以服务商账单为准。","hint"));
}
/** Accept asynchronous status only when it still matches the current page, event, and version. */
async function loadAgentStatus(id,eventId,version) {
  const seq=++agentStatusSeq; clearTimeout(agentPollTimer);
  try {
    const data=await api(`api/cases/${encodeURIComponent(id)}/agent-status`);
    if(seq!==agentStatusSeq || !isCurrentDetail(id) || selectedCase?.eventId!==eventId || selectedCase?.version!==version)return;
    if(data.eventId!==eventId || data.caseVersion!==version){await showCase(id);return;}
    const job=data.job||{},status=job.status, pending=status==="QUEUED"||status==="RUNNING";
    $("agentFlowOpen").hidden=agentRequestBusy||!job.runId; if(job.runId) $("agentFlowOpen").dataset.runId=job.runId;
    $("agentQuota").textContent=`今日调查次数（UTC）：${data.dailyUsed} / ${data.dailyLimit}；不构成金额预算上限。`;
    $("agentInvestigate").disabled=agentRequestBusy||data.active||data.dailyUsed>=data.dailyLimit||["PROCESSING","AUDIT_FAILED"].includes(selectedCase.status);
    if(pending){
      $("agentReview").replaceChildren(el("p",status==="QUEUED"?"AI 调查排队中…":"AI 调查进行中…","hint"));
      const parts=String(job.startedAt||job.createdAt||"").split(",").map(Number);
      if(parts.length===2&&parts.every(Number.isFinite)&&Date.now()-(Date.UTC(1840,11,31)+parts[0]*86400000+parts[1]*1000)>600000)$("agentReview").append(el("p","调查长时间未结束，请联系管理员检查；系统不会自动重试。","hint"));
      agentPollTimer=setTimeout(()=>loadAgentStatus(id,eventId,version),2500);
    }
    else if(job.result)renderAgentResult(job.result);
    else renderAgentResult(selectedCase.agentReview);
    if(data.active&&!pending){$("agentActionStatus").dataset.otherBusy="1";$("agentActionStatus").textContent="另一项调查正在处理，请稍后再试。";agentPollTimer=setTimeout(()=>loadAgentStatus(id,eventId,version),2500);}
    else if($("agentActionStatus").dataset.otherBusy==="1"){$("agentActionStatus").textContent="";delete $("agentActionStatus").dataset.otherBusy;}
  } catch(error) {
    if(seq===agentStatusSeq && isCurrentDetail(id)){$("agentInvestigate").disabled=true;$("agentQuota").textContent=`调查状态不可用：${error.message}`;}
  }
}
/** Open the submission status dialog without inferring execution stages before the task responds. */
function openAgentFlowPending() {
  clearTimeout(agentFlowTimer); const seq=++agentFlowSeq;
  $("agentFlowInfo").textContent="正在提交 AI 调查…";
  window.medFlow.renderAgentFlow($("agentFlowContent"),{},formatIrisTime,agentErrorText);
  if(!$("agentFlowDialog").open) $("agentFlowDialog").showModal();
  return seq;
}
/** Poll the selected runId and stop on event or case version changes; never show another investigation's trace. */
async function pollAgentFlow(context,seq) {
  if(seq!==agentFlowSeq || !$("agentFlowDialog").open || !isCurrentDetail(context.id))return;
  try {
    const data=await api(`api/cases/${encodeURIComponent(context.id)}/agent-status`);
    if(seq!==agentFlowSeq || !$("agentFlowDialog").open || !isCurrentDetail(context.id))return;
    if(!window.medFlow.matchesAgentRun(context,data)) { $("agentFlowInfo").textContent="调查任务或案例版本已变化，无法继续显示此流程。"; return; }
    const job=data.job||{};
    $("agentFlowInfo").textContent=`调查 #${job.runId} · 事件：${data.eventId} · 版本 ${data.caseVersion} · ${eventStatusLabels[job.status] || job.status}`;
    window.medFlow.renderAgentFlow($("agentFlowContent"),data,formatIrisTime,agentErrorText);
    if(["QUEUED","RUNNING"].includes(job.status))agentFlowTimer=setTimeout(()=>pollAgentFlow(context,seq),1500);
  } catch(error) { if(seq===agentFlowSeq && $("agentFlowDialog").open) $("agentFlowInfo").textContent=`调查状态不可用：${error.message}；请稍后重新打开。`; }
}
/** Show the latest investigation for the current case using the task ID from the authenticated status endpoint. */
function openExistingAgentFlow() {
  if(!selectedCase || !$("agentFlowOpen").dataset.runId)return;
  const context={id:selectedCase.encounterId,eventId:selectedCase.eventId,version:selectedCase.version,runId:Number($("agentFlowOpen").dataset.runId)};
  const seq=openAgentFlowPending(); pollAgentFlow(context,seq);
}
/** Submit once after user confirmation; never automatically retry requests with uncertain outcomes. */
async function startAgentInvestigation() {
  if(agentRequestBusy||!selectedCase||!isCurrentDetail(selectedCase.encounterId))return;
  const c={id:selectedCase.encounterId,eventId:selectedCase.eventId,version:selectedCase.version};
  const confirmText=interfaceLanguage==="en"?"Run AI investigation for this synthetic case? It may incur model charges. Daily limit: 100 attempts (UTC); this is not a monetary budget.":"为此合成案例发起 AI 调查？可能产生模型费用。每日上限 100 次（UTC），不等于金额预算上限。";
  if(!window.confirm(confirmText))return;
  const flowSeq=openAgentFlowPending();
  agentRequestBusy=true;$("agentInvestigate").disabled=true;$("agentFlowOpen").hidden=true;$("agentActionStatus").textContent="正在提交 AI 调查…";
  try {
    const job=await api(`api/cases/${encodeURIComponent(c.id)}/investigate`,{method:"POST",headers:{"Content-Type":"application/json; charset=utf-8"},body:JSON.stringify({eventId:c.eventId,version:c.version})});
    if(flowSeq===agentFlowSeq && $("agentFlowDialog").open && job.runId) pollAgentFlow({...c,runId:Number(job.runId)},flowSeq);
    if(isCurrentDetail(c.id)&&selectedCase?.eventId===c.eventId){$("agentActionStatus").textContent="调查已提交。";}
  } catch(error) {
    if(flowSeq===agentFlowSeq && $("agentFlowDialog").open) { $("agentFlowInfo").textContent=`提交未完成：${agentErrorText(error.message)}；结果可能未知，请关闭后刷新状态。`; $("agentFlowContent").replaceChildren(); }
    if(isCurrentDetail(c.id))$("agentActionStatus").textContent=`提交未完成：${agentErrorText(error.message)}；请刷新状态，不会自动重试。`;
  } finally {
    agentRequestBusy=false;
    if(isCurrentDetail(c.id)&&selectedCase?.eventId===c.eventId)await loadAgentStatus(c.id,c.eventId,c.version);
  }
}
/** Preserve existing case-level human review and use case versions to reject stale updates. */
async function submitReview() {
  if (!selectedCase || !isCurrentDetail(selectedCase.encounterId)) return;
  const current = selectedCase; $("reviewStatus").textContent = "提交中…";
  try {
    const result = await api(`api/cases/${encodeURIComponent(current.encounterId)}/review`, {method: "POST", headers: {"Content-Type": "application/json; charset=utf-8"}, body: JSON.stringify({version: current.version, decision: $("decision").value, reviewer: $("reviewer").value.trim(), reason: $("reason").value.trim()})});
    if (isCurrentDetail(current.encounterId) && selectedCase?.eventId === current.eventId) { $("reviewStatus").textContent = "案例复核已记录"; $("reason").value = ""; await showCase(result.encounterId || current.encounterId); } await refreshCases();
  } catch (error) { if (isCurrentDetail(current.encounterId) && selectedCase?.eventId === current.eventId) $("reviewStatus").textContent = `复核失败：${error.message}`; }
}
const scenarioDescriptions = {
  combined: "两条相同编码的有效布洛芬医嘱，病历提及肾功能不全。预期：2 条待核线索，触发演示依据检索。",
  duplicate: "两条相同编码的有效医嘱，病历不含肾功能线索。预期：1 条重复医嘱待核线索，触发演示依据检索。",
  renal: "一条有效布洛芬医嘱，病历提及肾功能不全。预期：1 条病历与用药待核线索，触发演示依据检索。",
  stopped: "两条同编码医嘱中一条已停用，病历不含肾功能线索。预期：不产生重复医嘱线索，仍触发演示依据检索。",
  inactive: "两条医嘱均已停用。预期：不命中演示线索，演示依据检索显示未触发。",
  routine: "仅一条有效医嘱，病历不含肾功能线索。预期：不命中演示线索，仍触发演示依据检索。"
};
let sampleRequest = 0, sendingFHIR = false;
/** Build isolated demo scenarios and replace references with encounter and patient IDs to avoid mixing old cases. */
async function loadSample() {
  const request = ++sampleRequest, scenario = $("scenarioSelect").value; let loaded = false;
  $("scenarioDescription").textContent = scenarioDescriptions[scenario]; $("send").disabled = true;
  try {
    const response = await fetch("sample.json"); if (!response.ok) throw new Error("示例文件不可用");
    let source = await response.text();
    if (request !== sampleRequest) return;
    const suffix = crypto.randomUUID().replaceAll("-", "").slice(0, 16);
    source = source.replaceAll("bundle-demo-001", `bundle-demo-${suffix}`).replaceAll("enc-demo-001", `enc-demo-${suffix}`).replaceAll("patient-demo-001", `patient-demo-${suffix}`);
    const bundle = JSON.parse(source);
  if (["renal", "routine"].includes(scenario)) bundle.entry = bundle.entry.filter(({resource}) => resource.id !== "med-002");
  if (["stopped", "inactive"].includes(scenario)) for (const {resource} of bundle.entry) {
    if (resource.resourceType === "MedicationRequest" && (scenario === "inactive" || resource.id === "med-002")) resource.status = "stopped";
  }
  if (scenario !== "combined" && scenario !== "renal") for (const {resource} of bundle.entry) {
    if (resource.resourceType === "Composition") resource.section[0].text.div = '<div xmlns="http://www.w3.org/1999/xhtml">演示病程记录，需结合临床资料复核。</div>';
  }
    $("fhir").value = JSON.stringify(bundle, null, 2); $("sentCase").hidden = true; $("sentFlow").hidden = true; $("sendStatus").textContent = "已生成新的合成场景"; loaded = true;
  } finally { if (request === sampleRequest && !sendingFHIR) $("send").disabled = !loaded; }
}
/** Submit the Bundle to the local demo endpoint and navigate to the resulting case. */
async function sendFHIR() {
  $("sentCase").hidden=true; $("sentFlow").hidden=true; delete $("sentFlow").dataset.eventId;
  sendingFHIR = true; $("scenarioSelect").disabled = true; $("loadSample").disabled = true; $("send").disabled = true; $("sendDemoBatch").disabled = true; $("sendStatus").textContent = "正在通过 IRIS Production…";
  try { const result = await api("api/fhir", {method: "POST", headers: {"Content-Type": "application/fhir+json; charset=utf-8"}, body: JSON.stringify(JSON.parse($("fhir").value))}); $("sendStatus").textContent = result.status === "AUDIT_FAILED" ? "FHIR 已接收，但审核派发失败；请到事件监控查看并重试。" : result.duplicate ? "已识别重复消息，返回已有结果" : result.status === "PROCESSING" ? "已接收，审核排队；打开案例后可刷新查看结果。" : "已接收，请查看案例状态。"; if (result.eventId) { $("sentFlow").hidden=false; $("sentFlow").dataset.eventId=result.eventId; } if (result.encounterId) { $("sentCase").href = `#detail/${encodeURIComponent(result.encounterId)}`; $("sentCase").hidden = false; } try { await refreshCases(); } catch (error) { $("sendStatus").textContent += `；案例列表刷新失败：${error.message}`; } }
  catch (error) { $("sendStatus").textContent = `发送未完成：${error.message}；如请求已发出但未收到响应，请检查事件监控。`; } finally { sendingFHIR = false; $("scenarioSelect").disabled = false; $("loadSample").disabled = false; $("send").disabled = false; $("sendDemoBatch").disabled = false; }
}
/** Submit three fixed synthetic scenarios in order; stop on failure without automatic retries or AI calls. */
async function sendDemoBatch() {
  if (sendingFHIR) return;
  $("sentCase").hidden=true; $("sentFlow").hidden=true; delete $("sentFlow").dataset.eventId;
  sendingFHIR=true; $("send").disabled=true; $("sendDemoBatch").disabled=true; $("loadSample").disabled=true; $("scenarioSelect").disabled=true;
  let accepted=0;
  try {
    const response=await fetch("sample.json"); if(!response.ok) throw new Error("示例文件不可用");
    const sample=await response.text();
    for (const scenario of ["combined","duplicate","inactive"]) {
      const suffix=crypto.randomUUID().replaceAll("-","").slice(0,16);
      const bundle=JSON.parse(sample.replaceAll("bundle-demo-001",`bundle-demo-${suffix}`).replaceAll("enc-demo-001",`enc-demo-${suffix}`).replaceAll("patient-demo-001",`patient-demo-${suffix}`));
      if(scenario!=="combined") for(const {resource} of bundle.entry) {
        if(resource.resourceType==="Composition") resource.section[0].text.div='<div xmlns="http://www.w3.org/1999/xhtml">演示病程记录，需结合临床资料复核。</div>';
        if(scenario==="inactive" && resource.resourceType==="MedicationRequest") resource.status="stopped";
      }
      const result=await api("api/fhir",{method:"POST",headers:{"Content-Type":"application/fhir+json; charset=utf-8"},body:JSON.stringify(bundle)});
      accepted++;
      if(result.eventId){$("sentFlow").dataset.eventId=result.eventId;$("sentFlow").hidden=false;}
      if(result.encounterId){$("sentCase").href=`#detail/${encodeURIComponent(result.encounterId)}`;$("sentCase").hidden=false;}
      if(result.status==="AUDIT_FAILED") throw new Error("审核派发失败，请在事件监控中处理");
      $("sendStatus").textContent=`已接收 ${accepted} / 3 条合成事件。`;
    }
    await refreshCases();
  } catch(error) { $("sendStatus").textContent=`批量演示停止：已接收 ${accepted} 条；${error.message}。如请求已发出但未收到响应，结果可能未知；请检查事件监控，系统不会自动重试。`; }
  finally { sendingFHIR=false; $("send").disabled=false; $("sendDemoBatch").disabled=false; $("loadSample").disabled=false; $("scenarioSelect").disabled=false; }
}
/** Search national policies and display sources, dates, and pending review status. */
async function loadPolicies(event) {
  if (event) event.preventDefault(); const box = $("policyList"), request = ++policyRequest; pageState.policies = 1; $("policiesPager").hidden = true; box.textContent = "检索中…";
  try {
    const result = await api(`api/policies?query=${encodeURIComponent($("policyQuery").value.trim())}`); if (request !== policyRequest) return;
    const items = result.items || [];
    const total = Number.isFinite(result.total) ? result.total : null;
    const draw = () => { box.replaceChildren(); const hint = el("p", undefined, "hint"); if (total !== null) hint.append(document.createTextNode(`知识库共 ${total} 条虚构演示依据 · `)); hint.append(document.createTextNode("关键词检索 · 当前接口最多返回 20 条 · 来源与生效状态须人工核实")); box.append(hint);
    for (const item of paginate("policies", items, draw)) {
      const card = el("article", undefined, "risk-card"); const dates = item.dates || {};
      const kind = {policy: "政策正文", attachment: "政策附件", supplement: "补充资料"}[item.recordType] || "类型待核";
      const parents = Array.isArray(item.parentPolicyIds) && item.parentPolicyIds.length ? ` · 关联政策 ${item.parentPolicyIds.join("、")}` : "";
      card.append(el("div", `${kind} · ${item.sourceId || "来源待核"}${parents}`, "risk-meta"), el("h3", item.title || "标题待核"), el("p", item.excerpt || "暂无提取片段"), el("p", `发布日期：${dates.publication_date || dates.publicationDate || "待核"} · 生效日期：${dates.effective_date || dates.effectiveDate || "待核"}`, "hint"), el("p", `核查标记：${Array.isArray(item.reviewFlags) ? item.reviewFlags.join("、") || "待核" : item.reviewFlags || "待核"}`, "hint"));
      const link = sourceLink(item.sourceUrl); if (link) card.append(link); box.append(card);
    }
    if (!items.length) box.append(el("p", "没有匹配的政策片段。", "empty")); }; draw();
  } catch (error) { if (request === policyRequest) box.textContent = `政策检索不可用：${error.message}`; }
}
/** Display read-only rule drafts without describing unapproved drafts as enabled. */
/** Retry a failed event manually, then reread server status. */
async function retryEvent(eventId, button) {
  button.disabled = true;
  const feedback = $("eventsStatus"); feedback.textContent = "正在提交重试…";
  try {
    await api(`api/events/${encodeURIComponent(eventId)}/retry`, {method: "POST", headers: {"Content-Type": "application/json; charset=utf-8"}, body: "{}"});
    feedback.textContent = "重试请求已提交，请查看最新事件状态。";
    await loadEvents();
  } catch (error) {
    feedback.textContent = `重试失败：${error.message}`;
    button.disabled = false;
  }
}
/** Sort recent events by recorded acceptance time only; do not invent ordering for missing timestamps. */
async function loadDashboardEvents() {
  const box=$("dashboardEvents");
  try {
    const data=await api("api/events"), items=Array.isArray(data.events)?data.events:[];
    const stamp=value=>{const parts=String(value||"").split(",").map(Number);return parts.length===2&&parts.every(Number.isFinite)?parts[0]*86400+parts[1]:0;};
    items.sort((a,b)=>stamp(b.receivedAt)-stamp(a.receivedAt)); box.replaceChildren();
    for(const event of items.slice(0,5)) {
      const row=el("div",undefined,"dashboard-event"), info=el("div");
      info.append(el("strong",event.eventId||"事件 ID 待补充"),el("small",`${event.encounterId||"待补充"} · ${formatIrisTime(event.receivedAt)} · ${eventStatusLabels[event.status]||event.status||"历史状态不可用"}`));
      const flow=el("button","查看执行流程","secondary"); flow.type="button"; flow.addEventListener("click",()=>openEventFlow(event)); row.append(info,flow); box.append(row);
    }
    if(!items.length)box.append(el("p","暂无事件。","empty"));
  } catch(error) { box.textContent="事件监控数据不可用。"; }
}
/** Show stages belonging to the selected event without reading or combining other events' history. */
function openEventFlow(event) {
  clearTimeout(flowPollTimer); const seq=++flowPollSeq;
  let previous="";
  /** Refresh only while the same event remains active so stale responses cannot overwrite a new dialog. */
  function draw(value) {
    const fingerprint=JSON.stringify([value.status,value.attempts,value.lastError,value.stages,value.historyAvailable]);
    $("flowDialogInfo").textContent = `事件：${value.eventId || "待补充"} · ${eventStatusLabels[value.status] || value.status || "历史状态不可用"} · 尝试次数：${value.attempts ?? "无记录"}`;
    if (fingerprint!==previous) { window.medFlow.renderFlow($("eventFlow"), value, formatIrisTime); previous=fingerprint; }
  }
  async function poll() {
    if (seq!==flowPollSeq || !$("flowDialog").open) return;
    try {
      const data=await api("api/events"), current=(data.events||[]).find(item=>item.eventId===event.eventId);
      if(seq!==flowPollSeq || !$("flowDialog").open) return;
      if(!current) { $("flowDialogInfo").textContent="事件记录不可用。"; return; }
      draw(current); if(["QUEUED","RUNNING"].includes(current.status)) flowPollTimer=setTimeout(poll,2500);
    } catch (_) { if(seq===flowPollSeq && $("flowDialog").open) $("flowDialogInfo").textContent="状态刷新失败，请重新打开流程。"; }
  }
  draw(event); if (!$("flowDialog").open) $("flowDialog").showModal();
  if(["QUEUED","RUNNING"].includes(event.status)) flowPollTimer=setTimeout(poll,2500);
}
/** Identify this submission by the server event ID instead of guessing message ownership from time windows. */
async function openSubmittedFlow() {
  const id=$("sentFlow").dataset.eventId;
  try { const data=await api("api/events"), event=(data.events || []).find(item=>item.eventId===id); if (!event) throw new Error("事件记录不可用"); openEventFlow(event); }
  catch(error) { $("sendStatus").textContent=`流程不可用：${error.message}`; }
}
/** Classify events by their existing status after fetching; never show stale statistics on failure. */
async function loadEvents() {
  const box = $("eventsList"), seq = ++eventRequest; box.textContent = "加载中…";
  try {
    const data=await api("api/events"); if (seq !== eventRequest) return;
    if (!Array.isArray(data.events)) throw new Error("INVALID_RESPONSE");
    eventItems=data.events; renderEvents();
  } catch (error) {
    if (seq !== eventRequest) return;
    eventItems=[]; for (const node of document.querySelectorAll("[data-event-count]")) node.textContent="—";
    $("eventsPager").hidden=true; box.textContent=`事件监控暂不可用：${error.message}`;
  }
}

/** Show category counts based on the current API response, paginated after filtering. */
function renderEvents() {
  const box=$("eventsList"), counts=window.medFlow.countEventGroups(eventItems);
  for (const node of document.querySelectorAll("[data-event-count]")) node.textContent=String(counts[node.dataset.eventCount]);
  for (const node of document.querySelectorAll("[data-event-group]")) node.setAttribute("aria-pressed",String(node.dataset.eventGroup===eventGroup));
  const filtered=window.medFlow.filterEvents(eventItems,eventGroup,$("eventQuery").value);
  box.replaceChildren();
    for (const event of paginate("events", filtered, renderEvents)) {
      const id = event.eventId || event.id;
      const row = el("article", undefined, "event-row");
      row.append(el("strong", id || "事件 ID 待补充"), el("span", `状态：${eventStatusLabels[event.status] || event.status || "历史状态不可用"} · 来源：${event.source || "待补充"}`), el("small", `就诊：${event.encounterId || "待补充"} · 接收：${formatIrisTime(event.receivedAt || event.at)} · 尝试次数：${event.attempts ?? "无记录"}`));
      const lastError = event.lastError || event.error || event.errorMessage;
      if (lastError) row.append(el("small", `失败原因：${typeof lastError === "object" ? JSON.stringify(lastError) : lastError}`, "event-error"));
      else if (event.status === "FAILED") row.append(el("small", "失败原因：服务端未提供详情。", "event-error"));
      if (Array.isArray(event.stages) && event.stages.length) row.append(el("small", `处理阶段：${event.stages.map((stage) => `${stage.name || "待核"}（${formatIrisTime(stage.at)}）`).join(" → ")}`));
      { const flowButton=el("button", "查看执行流程", "secondary event-retry"); flowButton.type="button"; flowButton.addEventListener("click", () => openEventFlow(event)); row.append(flowButton); }
      if (event.encounterId) { const link = el("a", "查看当前案例 →"); link.href = `#detail/${encodeURIComponent(event.encounterId)}`; row.append(link); }
      if ((event.status === "FAILED" || event.status === "QUEUED") && id) { const button = el("button", event.status === "QUEUED" ? "补投审核" : "手动重试", "secondary event-retry"); button.addEventListener("click", () => retryEvent(id, button)); row.append(button); }
      box.append(row);
    }
  if (!filtered.length) box.append(el("p", eventItems.length ? "当前分类没有匹配事件。" : "暂无事件。", "empty"));
}
/** Bind page actions and load health and cases independently so one API failure cannot block the page. */
async function init() {
  // The server authenticates initial and later requests; display the actual account and provide global logout.
  try { const state=await identityAdmin.request("/session"); if(!state.authenticated){location.replace("/med-audit/login");return;} $("site-user").textContent=state.username; currentWorkflowUser=state.username; $("reviewer").value=state.username; }
  catch (_) { location.replace("/med-audit/login"); return; }
  $("agentFlowClose").addEventListener("click",()=>$("agentFlowDialog").close());
  $("agentFlowDialog").addEventListener("close",()=>{clearTimeout(agentFlowTimer);++agentFlowSeq;});
  $("agentFlowOpen").addEventListener("click",openExistingAgentFlow);
  $("flowClose").addEventListener("click", () => $("flowDialog").close());
  $("flowDialog").addEventListener("close", () => { clearTimeout(flowPollTimer); ++flowPollSeq; });
  $("sentFlow").addEventListener("click", openSubmittedFlow);
  $("site-logout").addEventListener("click",async()=>{ $("site-logout").disabled=true; window.medAuditAdmin?.leave(); try{await identityAdmin.request("/logout",{});location.replace("/med-audit/login");}catch(error){showInitError(error);$("site-logout").disabled=false;} });
  // Support arrow-key tab switching while retaining hash navigation for Enter and mouse clicks.
  // Arrow keys switch module tabs and stay consistent with directly linked URLs.
  $("auditModule").addEventListener("keydown",event=>{if(!["ArrowLeft","ArrowRight","Home","End"].includes(event.key))return;event.preventDefault();const target=event.key==="Home"?$("auditTasksTab"):event.key==="End"?$("auditCasesTab"):document.activeElement===$("auditTasksTab")?$("auditCasesTab"):$("auditTasksTab");target.focus();location.hash=target.hash;});
  $("mcpModule").addEventListener("keydown",event=>{if(!["ArrowLeft","ArrowRight","Home","End"].includes(event.key))return;event.preventDefault();const active=document.activeElement;const target=event.key==="Home"?$("mcpServiceTab"):event.key==="End"?$("mcpTokensTab"):active===$("mcpServiceTab")?$("mcpTokensTab"):$("mcpServiceTab");target.focus();location.hash=target.hash;});
  $("sendDemoBatch").addEventListener("click", sendDemoBatch);
  window.addEventListener("hashchange", route); $("loadSample").addEventListener("click", () => loadSample().catch((error) => { $("sendStatus").textContent = error.message; })); $("scenarioSelect").addEventListener("change", () => loadSample().catch((error) => { $("sendStatus").textContent = error.message; })); $("send").addEventListener("click", sendFHIR);
  $("dashboardRefresh").addEventListener("click", () => { refreshCases().catch(showInitError); loadDashboardEvents(); });
  $("overviewRefresh").addEventListener("click", loadOverview);
  $("mcpRefresh").addEventListener("click", () => { mcpLogCursors=[""];mcpLogPage=0;loadMCPStatus();loadMCPLogs(); });
  $("mcpEnable").addEventListener("click",()=>setMCPService(true)); $("mcpDisable").addEventListener("click",()=>setMCPService(false));
  $("mcpLogPrev").addEventListener("click",()=>{if(mcpLogPage>0){mcpLogPage--;loadMCPLogs();}});
  $("mcpLogNext").addEventListener("click",()=>{if(mcpNextCursor){mcpLogPage++;mcpLogCursors[mcpLogPage]=mcpNextCursor;loadMCPLogs();}});
  $("agentInvestigate").addEventListener("click",startAgentInvestigation);
  $("detailRefresh").addEventListener("click", () => { const id = selectedCase?.encounterId; if (id) showCase(id).catch((error) => { $("risks").textContent = `案例刷新失败：${error.message}`; }); });
  const resetCasePage = () => { pageState.cases = 1; renderCases(); };
  $("workflowRefresh").addEventListener("click", loadWorkflowTasks);
  for (const [id, tab] of [["workflowTabAvailable", "AVAILABLE"], ["workflowTabProcessing", "PROCESSING"], ["workflowTabCompleted", "COMPLETED"]]) $(id).addEventListener("click", () => setWorkflowTab(tab));
  // Return to the first page when filters change; refresh and retry keep the current filter.
  for (const button of document.querySelectorAll("[data-event-group]")) button.addEventListener("click",()=>{eventGroup=button.dataset.eventGroup;pageState.events=1;renderEvents();});
  $("eventQuery").addEventListener("input",()=>{pageState.events=1;renderEvents();});
  $("caseQuery").addEventListener("input", resetCasePage); $("caseFilter").addEventListener("change", resetCasePage); $("reviewButton").addEventListener("click", submitReview); $("policyForm").addEventListener("submit", loadPolicies); $("eventsRefresh").addEventListener("click", loadEvents);
  loadSample().catch((error) => { $("sendStatus").textContent = error.message; });
  refreshCases().catch((error) => { $("caseList").textContent = `案例加载失败：${error.message}`; $("recentCases").textContent = `案例加载失败：${error.message}`; });
  await route();
}
/** Keep failures of important operations visible to the user. */
function showInitError(error) { $("app-error").textContent = `操作失败：${error.message}`; $("app-error").hidden = false; }
/** Read workflow tasks; do not overwrite the latest page results when the response is stale. */
async function loadWorkflowTasks() {
  const seq = ++workflowRequest, status = $("workflowStatus");
  status.textContent = "正在读取工作流任务…";
  try {
    const result = await api("api/workflow/tasks");
    if (seq !== workflowRequest) return;
    if (!Array.isArray(result.tasks)) throw new Error("INVALID_RESPONSE");
    workflowTasks = result.tasks;
    workflowDispatchErrors = Array.isArray(result.dispatchErrors) ? result.dispatchErrors : [];
    status.textContent = "";
    renderWorkflowDispatchErrors();
    renderWorkflowTasks();
    return true;
  } catch (error) {
    if (seq !== workflowRequest) return;
    workflowTasks = []; workflowDispatchErrors = []; $("workflowTasks").replaceChildren(); $("workflowPager").hidden = true;
    $("workflowDispatchErrors").replaceChildren(); $("workflowDispatchPager").hidden = true;
    status.textContent = "工作流任务不可用，请检查服务后刷新。";
    return false;
  }
}

/** Show event-level dispatch errors; tasks with uncertain outcomes only prompt manual inspection. */
function renderWorkflowDispatchErrors() {
  const box = $("workflowDispatchErrors"); box.replaceChildren();
  if (!workflowDispatchErrors.length) { $("workflowDispatchPager").hidden = true; return; }
  for (const item of paginate("workflowDispatch", workflowDispatchErrors, renderWorkflowDispatchErrors)) {
    const eventId = String(item.eventId || ""), missing = Number(item.missingCount) || 0, uncertain = Number(item.uncertainCount) || 0;
    const card = el("article", undefined, "risk-card");
    card.append(el("h3", "工作流派发异常"));
    const info = el("p", undefined, "hint");
    info.append(el("span", "就诊"), document.createTextNode(`: ${item.encounterId || "—"} · `), el("span", "事件"), document.createTextNode(`: ${eventId || "—"} · `), el("span", "异常代码"), document.createTextNode(`: ${item.error || "—"}`));
    const counts = el("p", undefined, "hint");
    counts.append(el("span", "未派发线索"), document.createTextNode(`: ${missing} · `), el("span", "结果不确定线索"), document.createTextNode(`: ${uncertain}`));
    card.append(info, counts);
    if (uncertain > 0) card.append(el("p", "存在派发结果不确定的线索，请管理员核查；系统不会盲目重复派发。", "hint"));
    if (missing > 0 && eventId) {
      const retry = el("button", "补派未映射线索", "secondary"); retry.type = "button"; retry.disabled = workflowDispatchBusy.has(eventId);
      retry.addEventListener("click", () => retryWorkflowDispatch(eventId, retry)); card.append(retry);
      card.append(el("p", "只补派未映射的线索，不会重投结果不确定的任务。", "hint"));
    } else if (uncertain === 0) card.append(el("p", "请联系管理员检查派发异常。", "hint"));
    box.append(card);
  }
}

/** Only ask the server to re-dispatch findings with no mapping; never rebuild tasks in the browser. */
async function retryWorkflowDispatch(eventId, button) {
  if (!eventId || workflowDispatchBusy.has(eventId)) return;
  workflowDispatchBusy.add(eventId); button.disabled = true;
  $("workflowStatus").textContent = "正在提交补派请求…";
  try {
    await api(`api/workflow/events/${encodeURIComponent(eventId)}/retry`, {method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({})});
    workflowDispatchBusy.delete(eventId);
    const loaded = await loadWorkflowTasks();
    if (loaded) $("workflowStatus").textContent = "补派请求已处理，请核对最新状态。";
  } catch (error) {
    $("workflowStatus").textContent = "补派结果未确认，请刷新状态后再试。";
  } finally { workflowDispatchBusy.delete(eventId); if (button.isConnected) button.disabled = false; }
}

/** Switch workflow task tabs by status; return to the first page after switching. */
function setWorkflowTab(tab) {
  workflowTab = tab; pageState.workflow = 1;
  for (const [id, value] of [["workflowTabAvailable", "AVAILABLE"], ["workflowTabProcessing", "PROCESSING"], ["workflowTabCompleted", "COMPLETED"]]) $(id).setAttribute("aria-selected", String(value === tab));
  renderWorkflowTasks();
}
/** Show allowed actions by task status; reviewer identity is determined by the server session. */
function renderWorkflowTasks() {
  const box = $("workflowTasks"); box.replaceChildren();
  // Available holds only claimable tasks; Processing gathers claimed, syncing and abnormal states; Completed is separate.
  const tabbed = workflowTasks.filter(task => workflowTab === "AVAILABLE" ? task.status === "AVAILABLE" : workflowTab === "COMPLETED" ? task.status === "COMPLETED" : !["AVAILABLE", "COMPLETED"].includes(task.status));
  if (!tabbed.length) { $("workflowPager").hidden = true; box.append(el("p", "该状态下暂无工作流任务。", "empty")); return; }
  const statuses = {AVAILABLE:"待领取", CLAIMED:"处理中", COMPLETED:"已完成", SYNC_PENDING:"等待同步", REVIEW_MISMATCH:"审核记录不一致", QUEUED:"排队中", DISPATCHING:"正在创建", FAILED:"创建失败"};
  for (const task of paginate("workflow", tabbed, renderWorkflowTasks)) {
    const id = String(task.taskId ?? ""), card = el("article", undefined, "risk-card");
    const owner = String(task.assignee || ""), ownTask = !!currentWorkflowUser && owner.toUpperCase() === currentWorkflowUser.toUpperCase();
    const title = el("h3", undefined); title.append(el("span", "工作流任务"), document.createTextNode(` #${id}`));
    const state = task.stale ? "事件已过期" : (statuses[task.status] || "状态未知");
    card.append(title, el("span", state, "status-chip"));
    // The summary shows only findings the backend matched from the current event; content is always treated as text.
    const summary = task.findingSummary || {}, overview=el("div", undefined, "workflow-finding-summary");
    if (summary.title || summary.explanation) {
      if (summary.title) overview.append(el("h4", summary.title));
      if (summary.explanation) overview.append(el("p", summary.explanation));
      if (summary.level) overview.append(el("span", summary.level, "workflow-finding-level"));
    } else overview.append(el("p", task.stale ? "历史疑点概要不可用，请查看案例。" : "疑点概要暂不可用，请查看案例。", "hint"));
    card.append(overview);
    const caseLine = el("p", undefined, "hint");
    caseLine.append(el("span", "就诊"), document.createTextNode(`: ${task.encounterId || "—"} · `), el("span", "事件"), document.createTextNode(`: ${task.eventId || "—"} · `), el("span", "疑点"), document.createTextNode(`: ${task.findingId || "—"}`));
    const info = el("p", undefined, "hint");
    info.append(el("span", "处理人"), document.createTextNode(`: ${owner || "—"} · `), el("span", "任务 ID"), document.createTextNode(`: ${task.nativeTaskId || "—"} · `), el("span", "投递状态"), document.createTextNode(`: ${task.dispatchState || "—"}`));
    card.append(caseLine, info);
    if (task.encounterId) { const link = el("a", "查看案例 →"); link.href = `#detail/${encodeURIComponent(task.encounterId)}`; card.append(link); }
    if (task.status === "REVIEW_MISMATCH") card.append(el("p", "任务与应用审核记录不一致，请管理员核对；系统不会自动修复。", "hint"));
    if (task.stale) card.append(el("p", "该任务属于旧事件，不能操作，请查看当前案例。", "hint"));
    else if (task.syncPending) {
      card.append(el("p", "复核提交等待同步；请由原处理人恢复并核对记录。", "hint"));
      if (ownTask) {
        const retry = el("button", "恢复待同步任务", "secondary"); retry.type = "button"; retry.disabled = workflowBusy.has(id);
        retry.addEventListener("click", () => submitWorkflowAction(id, "retry", {}, retry)); card.append(retry);
      }
    } else if (task.status === "AVAILABLE") {
      const claim = el("button", "领取任务", "secondary"); claim.type = "button"; claim.disabled = workflowBusy.has(id);
      claim.addEventListener("click", () => submitWorkflowAction(id, "claim", {}, claim)); card.append(claim);
    } else if (task.status === "CLAIMED" && ownTask) {
      const form = el("form", undefined, "finding-form");
      const decision = el("select"); decision.setAttribute("aria-label", "工作流处理决定");
      for (const [value, label] of [["CONFIRMED", "确认风险"], ["DISMISSED", "排除风险"]]) { const option = el("option", label); option.value = value; decision.append(option); }
      const reason = el("input"); reason.maxLength = 500; reason.required = true; reason.placeholder = "填写处理理由"; reason.setAttribute("aria-label", "处理理由");
      const submit = el("button", "完成工作流任务"); submit.type = "submit"; submit.disabled = workflowBusy.has(id);
      form.append(decision, reason, submit);
      form.addEventListener("submit", event => {
        event.preventDefault();
        const text = reason.value.trim();
        if (!text) { $("workflowStatus").textContent = "请填写处理理由。"; return; }
        submitWorkflowAction(id, "complete", {eventId: task.eventId, version: task.findingVersion, decision: decision.value, reason: text}, submit);
      });
      card.append(form);
    } else if (task.status === "CLAIMED") card.append(el("p", "任务已由其他人员领取。", "hint"));
    else if (task.status === "FAILED") card.append(el("p", "工作流任务创建失败，请联系管理员检查投递状态。", "hint"));
    else if (["QUEUED", "DISPATCHING"].includes(task.status)) card.append(el("p", "任务尚在创建，请刷新后查看。", "hint"));
    box.append(card);
  }
}

/** Submit explicitly once; on failure or uncertain response, refresh first to avoid blind repeats. */
async function submitWorkflowAction(id, action, body, button) {
  if (!id || workflowBusy.has(id)) return;
  workflowBusy.add(id); button.disabled = true;
  $("workflowStatus").textContent = "正在提交工作流操作…";
  try {
    await api(`api/workflow/tasks/${encodeURIComponent(id)}/${action}`, {method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify(body)});
    workflowBusy.delete(id);
    const loaded = await loadWorkflowTasks();
    if (loaded) $("workflowStatus").textContent = "工作流状态已更新。";
    refreshCases().catch(() => {});
  } catch (error) {
    // Show known permission errors explicitly; keep the result unconfirmed on network errors to avoid blind retries.
    $("workflowStatus").textContent = error.message === "WORKFLOW_FORBIDDEN" ? "当前账号没有工作流审核权限，请联系管理员。" : "工作流操作未确认，请刷新状态后再试。";
  } finally { workflowBusy.delete(id); if (button.isConnected) button.disabled = false; }
}

// Translate workbench UI labels only; do not machine-translate original policies, clinical records, user input, or native IRIS pages.
const englishText = {
  "FHIR 文件接入":"FHIR File Intake", "上传合成 FHIR Bundle，查看文件适配器和审核事件的实际处理记录。":"Upload a synthetic FHIR Bundle and inspect recorded adapter and audit activity.", "上传测试文件":"Upload a test file", "支持 UTF-8 JSON 文件，最大 1 MiB。文件会交给 IRIS 文件 Adapter；请勿上传真实患者数据。":"UTF-8 JSON, up to 1 MiB. The IRIS file adapter processes the file. Use synthetic data only.", "选择 FHIR 文件":"Choose a FHIR file", "上传并处理":"Upload and process", "文件处理记录":"File processing history", "展示最近 100 条页面上传记录；失败文件会保留并定期重试。":"Shows the latest 100 uploads; failed files are retained and retried periodically.", "调用流程":"Execution flow", "文件处理记录分页":"File history pages", "文件已上传":"File uploaded", "Adapter 已接收处理":"Adapter processed file", "重复文件":"Duplicate file", "文件处理中":"Processing file", "业务服务已接收":"Business service received file", "等待 Adapter":"Waiting for adapter", "文件处理失败":"File processing failed", "正在上传…":"Uploading…", "上传成功，等待文件 Adapter。":"Uploaded; waiting for the file adapter.", "请选择不超过 1 MiB 的 JSON 文件。":"Choose a JSON file up to 1 MiB.", "文件不是有效的 UTF-8 文本。":"The file is not valid UTF-8.", "暂无文件处理记录。":"No file processing records.", "查看文件流程":"View file flow", "文件状态":"File status", "审核事件":"Audit event", "等待事件记录":"Waiting for event record", "仅展示已记录的文件状态和审核阶段。":"Only recorded file states and audit stages are shown.", "仅展示已记录的文件状态和审核阶段，并非完整 IRIS 消息追踪。":"Only recorded file states and audit stages are shown; this is not a complete IRIS message trace.", "业务接收记录":"Business intake record",
  "审核记录不一致":"Review mismatch", "任务与应用审核记录不一致，请管理员核对；系统不会自动修复。":"The task and application review do not match. An administrator must investigate; no automatic repair is attempted.",
  "派发异常分页":"Dispatch error pagination", "工作流派发异常":"Workflow dispatch issue", "异常代码":"Error code", "未派发线索":"Unsent findings", "结果不确定线索":"Findings with uncertain outcomes", "存在派发结果不确定的线索，请管理员核查；系统不会盲目重复派发。":"Some dispatch outcomes are uncertain. An administrator must investigate; the system will not blindly resend them.", "补派未映射线索":"Dispatch unmapped findings", "只补派未映射的线索，不会重投结果不确定的任务。":"Only unmapped findings are dispatched; tasks with uncertain outcomes are not resent.", "请联系管理员检查派发异常。":"Ask an administrator to inspect the dispatch issue.", "正在提交补派请求…":"Submitting dispatch request…", "补派请求已处理，请核对最新状态。":"Dispatch request processed. Check the latest status.", "补派结果未确认，请刷新状态后再试。":"The dispatch result was not confirmed. Refresh the status before trying again.",
  "当前账号没有工作流审核权限，请联系管理员。":"This account does not have workflow review permission. Contact an administrator.",
  "历史疑点概要不可用，请查看案例。":"Historical finding summary is unavailable; view the case.", "疑点概要暂不可用，请查看案例。":"Finding summary is unavailable; view the case.",
  "事件状态分类":"Event status groups", "全部事件":"All events", "排队与处理中":"Queued and running", "其他与历史":"Other and historical", "搜索事件或就诊 ID":"Search event or encounter ID", "输入事件 ID 或就诊 ID":"Enter an event or encounter ID", "当前分类没有匹配事件。":"No events match the current filter.",
  "待办任务":"To-do Tasks", "审核案例":"Audit Cases", "审核案例分页":"Audit case pages", "← 返回审核案例":"← Back to audit cases",
  "工作流任务状态":"Workflow task status", "已完成":"Completed", "该状态下暂无工作流任务。":"No workflow tasks in this state.", "刷新工作流任务":"Refresh workflow tasks", "工作流任务分页":"Workflow task pagination", "请先领取任务并查看案例，再使用本列表完成复核。案例整体复核不等于完成任务。":"Claim a task and review its case before completing it here. A case-level review does not complete the task.", "案例整体复核不会完成工作流任务；请在审核任务页处理。":"A case-level review does not complete workflow tasks; handle them on the Audit Tasks page.", "已创建任务的疑点请在审核任务页领取并完成，原有疑点复核入口不能替代任务。":"For findings with a task, claim and complete it on the Audit Tasks page; the legacy finding review does not complete that task.", "正在读取工作流任务…":"Loading workflow tasks…", "工作流任务不可用，请检查服务后刷新。":"Workflow tasks are unavailable. Check the service and refresh.", "工作流任务":"Workflow task", "待领取":"Available", "等待同步":"Synchronization pending", "正在创建":"Creating", "创建失败":"Creation failed", "事件已过期":"Event superseded", "就诊":"Encounter", "事件":"Event", "疑点":"Finding", "处理人":"Assignee", "任务 ID":"Task ID", "投递状态":"Dispatch status", "查看案例 →":"View case →", "该任务属于旧事件，不能操作，请查看当前案例。":"This task belongs to an earlier event and cannot be changed. View the current case.", "复核提交等待同步；请由原处理人恢复并核对记录。":"The review was recorded; the native task is awaiting synchronization. The original reviewer can retry.", "恢复待同步任务":"Retry synchronization", "领取任务":"Claim task", "工作流处理决定":"Workflow review decision", "完成工作流任务":"Complete workflow task", "请填写处理理由。":"Enter a review reason.", "任务已由其他人员领取。":"This task is assigned to another user.", "工作流任务创建失败，请联系管理员检查投递状态。":"Task creation failed. Ask an administrator to inspect dispatch.", "任务尚在创建，请刷新后查看。":"The task is being created; refresh to check its status.", "正在提交工作流操作…":"Submitting workflow action…", "工作流状态已更新。":"Workflow status updated.", "工作流操作未确认，请刷新状态后再试。":"The workflow action was not confirmed. Refresh before trying again.",
  "发起 AI 调查":"Run AI investigation", "正在读取调查状态…":"Loading investigation status…", "AI 调查排队中…":"AI investigation queued…", "AI 调查进行中…":"AI investigation in progress…", "调查长时间未结束，请联系管理员检查；系统不会自动重试。":"The investigation is taking unusually long. Contact an administrator; it will not be retried automatically.", "另一项调查正在处理，请稍后再试。":"Another investigation is in progress. Try again later.", "正在提交 AI 调查…":"Submitting AI investigation…", "调查已提交。":"Investigation submitted.", "费用未计算，请以服务商账单为准。":"Cost is not calculated; refer to the provider bill.",
  "MCP 管理":"MCP Management",
  "监控网关连通性、控制工具访问并查看调用记录。":"Monitor gateway reachability, control tool access, and view call logs.", "服务状态":"Service status", "开启服务":"Enable service", "关闭服务":"Disable service", "服务访问":"Service access", "已开启":"Enabled", "已关闭":"Disabled", "网关连通性":"Gateway connectivity", "可连通":"Reachable", "不可连通":"Unreachable", "历史调用":"Recorded calls", "成功 / 失败":"Succeeded / failed", "成功":"Succeeded", "拒绝":"Denied", "失败":"Failed", "调用日志":"Call logs", "仅记录工具调用，不包含令牌和完整请求":"Tool calls only; tokens and full requests are not recorded", "开关控制 MCP 工具访问；关闭后新调用会被拒绝，进行中的调用可能完成。网关进程仍保持运行。":"The switch controls MCP tool access; new calls are rejected when disabled, while in-flight calls may finish. The gateway process remains running.", "网关连通表示收到 HTTP 响应，不代表认证或工具调用成功。":"A reachable gateway returned an HTTP response; this does not confirm authentication or tool execution.", "正在更新服务状态…":"Updating service status…", "服务已开启。":"Service enabled.", "服务已关闭。":"Service disabled.",
  "演示说明":"Demo information",
  "这是 IRIS 原生管理页面，请使用自己的 IRIS 账号登录。配置修改和启停会直接影响本地演示环境。":"Sign in to the native IRIS management page with your own account. Changes and start/stop actions affect the demo.", "Production 管理入口暂不可用，请检查 IRIS 服务。":"The Production management page is unavailable. Check the IRIS service.",
  "AI 调查调用流程":"AI investigation flow", "查看调查流程":"View investigation flow", "仅显示本次调查已记录的状态和工具调用。":"Only recorded task states and tool calls for this investigation are shown.", "正在提交调查，等待任务编号…":"Submitting investigation; waiting for task ID…", "调查已排队":"Investigation queued", "工作进程已领取":"Worker claimed task", "开始模型调用":"Model call started", "病例证据工具已返回":"Case evidence tool returned", "政策证据工具已返回":"Policy evidence tool returned", "输出与引用校验通过":"Output and citations validated", "调查完成":"Investigation completed", "调查失败":"Investigation failed", "时间未记录":"Time not recorded", "没有可用的工具调用明细；历史任务可能未记录。":"No tool-call details available; historical tasks may not have recorded them.", "调查进行中，等待新的实际调用记录…":"Investigation in progress; waiting for recorded calls…", "调查任务或案例版本已变化，无法继续显示此流程。":"The task or case version changed; this flow cannot be displayed further.",
  "审核失败，结果不可用，请查看事件监控。":"Audit failed; results are unavailable. Check Event Monitor.", "事件记录不可用。":"Event record unavailable.", "状态刷新失败，请重新打开流程。":"Status refresh failed; reopen the flow.", "检索范围：合成演示库 · 手工构造的固定测试向量 · 相似度不代表政策适用性。":"Scope: synthetic evidence · Hand-crafted test vectors · Similarity does not establish applicability.", "阶段记录可能包含多次尝试，未按重试次数区分。":"Stages may include multiple attempts and are not separated by retry.", "最近审核动态":"Recent audit activity", "批量演示 3 条":"Run 3 demo cases", "Token 用量无可用记录。":"No token usage recorded.", "调查耗时无可用记录。":"No investigation duration recorded.", "AI 历史调查统计不可用。":"AI investigation statistics unavailable.", "统计基于历史任务；当前模型连通性未检测。":"Based on recorded tasks; current model connectivity has not been tested.",
  "业务阶段回放 · 动画速度不代表真实耗时":"Recorded business stages · Animation speed is not actual elapsed time", "该事件的阶段记录不可用。":"Stage history is unavailable for this event.", "重新回放":"Replay", "事件流程回放":"Event flow replay", "查看执行流程":"View execution flow", "关闭":"Close", "事件处理失败":"Event processing failed",
  "查询内容无效或超过模型长度限制。":"The query is invalid or exceeds the model length limit.", "检索上传文档":"Search uploaded documents", "检索上传内容；来源与适用性需人工核实，不代表医保政策依据。":"Search uploaded content. Verify its source and applicability; it is not an insurance policy authority.", "输入要检索的内容":"Enter text to search", "上传文档检索内容":"Uploaded document search query", "输入查询内容后开始检索。":"Enter a query to search.", "请输入检索内容。":"Enter a search query.", "正在检索上传文档…":"Searching uploaded documents…", "未找到匹配的上传文档。":"No matching uploaded documents found.", "检索完成，结果仅供人工核实。":"Search complete; verify results manually.", "上传内容 · 待人工核实":"Uploaded content · Human verification required", "任务编号":"Job ID", "片段序号":"Chunk index", "相似度":"Similarity", "模型指纹":"Model fingerprint", "检索失败，请检查服务状态。":"Search failed; check service status.", "返回结果不可用。":"Search results are unavailable.",
  "文件向量库":"Document Vectors", "上传文件":"Upload document", "刷新状态":"Refresh status", "选择文件":"Choose file", "上传并向量化":"Upload and vectorize", "导入记录":"Import history", "上传文档后使用本地中文模型生成向量并写入 IRIS。":"Upload documents and generate vectors locally for storage in IRIS.", "处理进程尚未连接，请检查本地启动脚本。":"Worker has not connected; check the local startup script.", "暂无导入记录。":"No imports yet.", "正在上传…":"Uploading…", "已提交，等待本地向量化。":"Submitted; waiting for local vectorization.", "请选择不超过 2 MB 的非空文件。":"Choose a non-empty file up to 2 MB.", "支持 UTF-8 编码的 TXT、Markdown 和 DOCX，单个文件不超过 2 MB。上传内容独立保存，来源与适用性均待人工核实。":"Supports UTF-8 TXT, Markdown and DOCX files up to 2 MB. Uploads are stored separately; verify their source and applicability.",
  "退出登录":"Sign out", "正在检查登录…":"Checking session…", "管理员访问":"Administrator access", "正在检查管理员会话…":"Checking administrator session…", "管理员未登录":"Administrator not signed in", "请使用 IRIS 管理员账号登录。":"Sign in with an IRIS administrator account.", "用户名":"Username", "密码":"Password", "登录":"Sign in", "退出管理员":"Sign out", "已退出管理员会话。":"Administrator signed out.",
  "MCP 服务":"MCP Service", "MCP Token 管理":"MCP Tokens", "AI 设置":"AI Settings", "医保审核只读 MCP 工具与已记录的调用情况。":"Read-only medical audit MCP tools and recorded calls.", "历史调用统计并非实时连通性探测。客户端需要独立 Token 和明确病例授权。":"Historical calls do not establish current connectivity. Clients require a separate token and explicit case access.", "服务与工具":"Service and tools", "接口按病例和预期版本限制访问；Token 撤销和过期会在每次调用时复核。":"Access is limited by case and version; expiry and revocation are checked on every call.", "管理 MCP Token →":"Manage MCP Tokens →", "暂无调用记录。":"No calls recorded.", "实时网关连通性：未检测。":"Live gateway connectivity: Not checked.",
  "运行大屏":"System Overview", "系统运行大屏":"System Overview", "汇总本地演示系统当前可读取的运行数据。":"A summary of currently available local demo system data.", "刷新大屏":"Refresh Overview", "仅统计本地合成数据；历史调用结果不代表服务当前可用。":"Synthetic local data only; past calls do not establish current service availability.", "审核与事件状态":"Audit and event status", "AI 与服务":"AI and services", "合成就诊":"Synthetic encounters", "审核处理中":"Audits in progress", "待人工复核":"Awaiting review", "审核失败":"Audit failed", "病例状态":"Case status", "待处理事件":"Active events", "失败事件":"Failed events", "事件台账":"Event ledger", "不可用":"Unavailable", "事件监控数据不可用。":"Event data unavailable.", "IRIS Production：运行中":"IRIS Production: Running", "IRIS Production：未运行":"IRIS Production: Stopped", "IRIS Production：状态不可用":"IRIS Production: Unavailable", "AI Hub：历史调查结果可在案例详情查看；当前模型连通性未检测。":"AI Hub: View past investigations in case details; current model connectivity has not been tested.", "MCP 服务：状态不可用。":"MCP service: Status unavailable.",
  "AI Hub 审核建议":"AI Hub Review Suggestion", "建议仅供人工核查；模型未运行或失败不代表审核通过。":"Suggestions require human review; a missing or failed model run does not imply approval.", "当前案例尚未运行 AI Hub 调查。":"AI Hub has not investigated this case.",
  "医保智能审核 · 本地演示":"Medical Insurance Audit · Local Demo", "医":"M", "医保智能审核":"Medical Insurance Audit", "IRIS 本地演示":"IRIS Local Demo", "工作空间":"WORKSPACE", "工作台":"Dashboard", "审核任务":"Audit Tasks", "知识依据库":"Knowledge Evidence Library", "事件监控":"Event Monitor", "FHIR 测试入口":"FHIR Test", "仅合成数据":"Synthetic data only", "演示环境 · 未接入医院":"Demo · No hospital connected", "连接中…":"Connecting…", "演示用户":"Demo user",
  "本地演示 · 仅使用合成数据。演示提示和政策检索结果仅供人工核查，不构成违规认定或临床建议。":"Local demo · Synthetic data only. Alerts and policy search results require human review and do not constitute violation findings or clinical advice.",
  "审核工作台":"Audit Dashboard", "从合成事件到人工核查的演示闭环":"A demonstration from synthetic events to human review", "刷新数据":"Refresh", "统计当前加载的合成案例及其疑点，不代表医院实际绩效。":"Statistics cover loaded synthetic cases and do not represent hospital performance.", "审核任务（前5条）":"Audit Tasks (first 5)", "查看全部 →":"View all →", "刷新":"Refresh", "搜索就诊 ID":"Search encounter ID", "案例状态":"Case status", "全部状态":"All statuses", "处理中":"Processing", "待核查":"Needs review", "已确认":"Confirmed", "已排除":"Dismissed", "加载中…":"Loading…", "← 返回审核任务":"← Back to audit tasks", "任务详情":"Task Details", "选择案例后查看":"Select a case", "刷新详情":"Refresh details", "等待消息":"Waiting for message", "疑点与逐条处置":"Findings and individual review", "以下为本地演示规则提示；逐条复核不会修改医嘱、病历或费用。":"These demo rule alerts do not change orders, medical records or charges.", "请选择案例。":"Select a case.", "合成演示依据":"Synthetic evidence", "消息流转":"Message flow", "案例整体复核（兼容入口）":"Case review (legacy)", "历史案例级复核与逐条疑点处置分别记录。":"Case-level reviews and individual finding decisions are recorded separately.", "处理决定":"Decision", "继续核查":"Continue review", "确认风险":"Confirm risk", "排除风险":"Dismiss risk", "复核人":"Reviewer", "理由":"Reason", "提交案例复核":"Submit case review", "关键词检索虚构演示依据；样例不是实际医保政策。":"Search fictional demonstration evidence; these samples are not insurance policies.", "检索":"Search", "输入关键词进行检索。":"Enter a keyword to search.", "查看本地演示事件及处理状态。":"View local demo events and processing status.", "事件状态反映本地演示处理记录；失败事件可手动重试。当前不代表生产级队列或自动补偿能力。":"Statuses reflect local demo processing. Failed events can be retried manually; automatic recovery is not provided.", "选择合成场景，查看预期线索并投递到本地演示端点。":"Select a synthetic scenario, review the expected findings and send it to the local endpoint.", "该入口为演示 collection 接收端点，不代表完整 FHIR Server。请勿输入真实患者数据。":"This demo collection endpoint is not a complete FHIR server. Do not enter real patient data.", "测试场景":"Test scenario", "重复医嘱与肾功能线索":"Duplicate orders and renal finding", "重复医嘱":"Duplicate orders", "肾功能病历与布洛芬":"Renal history and ibuprofen", "一条医嘱已停用":"One order stopped", "无有效医嘱":"No active orders", "未命中演示线索":"No demo findings", "重新生成场景":"Regenerate scenario", "每次生成都会创建新的合成就诊和 Bundle ID；重复发送未修改的内容会按同一事件处理。审核结果只供人工核查。":"Each generation creates new synthetic encounter and Bundle IDs. Resending unchanged content uses the same event. Results require human review.", "发送到 IRIS":"Send to IRIS", "查看本次案例 →":"View this case →", "查看本地演示环境的 Production 配置与运行情况。":"View the local demo Production configuration and status.", "在新窗口打开 ↗":"Open in new window ↗", "这是 IRIS 原生管理页面，请使用 IRIS 账号登录。配置修改和启停会直接影响本地演示环境。":"Sign in to the native IRIS management page. Changes and start/stop actions affect the local demo.", "本地演示 · 真实医院接入前需另行完成授权、安全、政策版本与业务验证。":"Local demo · Hospital integration requires separate authorization, security, policy and business validation.",
  "IRIS Production 运行中":"IRIS Production running", "IRIS Production 未启动":"IRIS Production stopped", "合成案例":"Synthetic cases", "当前案例总数":"Total loaded cases", "待处理疑点":"Open findings", "待复核或继续核查":"Pending or under review", "已处理疑点":"Reviewed findings", "已确认或已排除":"Confirmed or dismissed", "查看详情 →":"View details →", "没有符合条件的案例。":"No matching cases.", "暂无案例，可在 FHIR 测试入口发送合成示例。":"No cases. Send a synthetic sample from FHIR Test.", "待复核":"Pending review", "排队中":"Queued", "处理成功":"Succeeded", "处理失败":"Failed", "已被新事件取代":"Superseded", "历史状态不可用":"Historical status unavailable", "待补充":"Not provided", "待核":"Unverified", "待核实":"To verify", "上一页":"Previous", "下一页":"Next", "手动重试":"Retry", "补投审核":"Resubmit audit", "查看当前案例 →":"View current case →", "暂无事件。":"No events.", "已生成新的合成场景":"A new synthetic scenario is ready", "已识别重复消息，返回已有结果":"Duplicate event detected; existing result returned", "已接收，审核排队；打开案例后可刷新查看结果。":"Accepted and queued; open the case and refresh to see the result.", "FHIR 已接收，但审核派发失败；请到事件监控查看并重试。":"FHIR accepted, but audit dispatch failed. Check Event Monitor and retry.", "已接收，请查看案例状态。":"Accepted; check the case status.", "正在通过 IRIS Production…":"Sending through IRIS Production…", "没有匹配的政策片段。":"No matching policy excerpts.", "关键词检索 · 当前接口最多返回 20 条 · 来源与生效状态须人工核实":"Keyword search · The API returns up to 20 results · Verify sources and effective status", "待核实项":"Items to verify", "提交疑点复核":"Submit finding review", "疑点处置接口或状态尚不可用":"Finding review is not currently available", "填写处理理由":"Enter review reason", "疑点处理决定":"Finding decision", "处理理由":"Review reason", "审核排队或处理中，请刷新详情查看结果。":"Audit queued or running. Refresh to see the result.", "未命中本地演示知识条目。":"No local demo knowledge entries matched.", "暂无消息阶段。":"No message stages.", "该历史案例尚未执行演示依据检索。":"National policy retrieval has not run for this historical case.", "最近一次案例复核":"Latest case review", "查看来源原文 ↗":"View original source ↗", "已检索，待核实":"Retrieved; verification required", "未触发":"Not triggered", "未找到依据":"No evidence found", "检索不可用":"Retrieval unavailable", "正在提交重试…":"Submitting retry…", "重试请求已提交，请查看最新事件状态。":"Retry submitted. Check the latest event status.", "提交中…":"Submitting…", "案例复核已记录":"Case review recorded", "输入就诊 ID":"Enter encounter ID", "输入政策名称、文号或关键词":"Enter a policy title, document number or keyword", "政策关键词":"Policy keyword", "审核任务分页":"Audit task pages", "事件监控分页":"Event pages", "合成演示分页":"Policy pages", "主导航":"Main navigation", "IRIS Production 管理页面":"IRIS Production management page",
  "两条相同编码的有效布洛芬医嘱，病历提及肾功能不全。预期：2 条待核线索，触发演示依据检索。":"Two active ibuprofen orders share a code; the record mentions renal impairment. Expected: 2 findings and policy retrieval.",
  "两条相同编码的有效医嘱，病历不含肾功能线索。预期：1 条重复医嘱待核线索，触发演示依据检索。":"Two active orders share a code, with no renal finding. Expected: 1 duplicate-order finding and policy retrieval.",
  "一条有效布洛芬医嘱，病历提及肾功能不全。预期：1 条病历与用药待核线索，触发演示依据检索。":"One active ibuprofen order and a renal impairment note. Expected: 1 finding and policy retrieval.",
  "两条同编码医嘱中一条已停用，病历不含肾功能线索。预期：不产生重复医嘱线索，仍触发演示依据检索。":"One of two same-code orders is stopped, with no renal finding. Expected: no duplicate-order finding; policy retrieval still runs.",
  "两条医嘱均已停用。预期：不命中演示线索，演示依据检索显示未触发。":"Both orders are stopped. Expected: no findings; policy retrieval is not triggered.",
  "仅一条有效医嘱，病历不含肾功能线索。预期：不命中演示线索，仍触发演示依据检索。":"One active order, with no renal finding. Expected: no findings; policy retrieval still runs.",
  "同次就诊存在相同药品编码的医嘱":"Orders with the same drug code in one encounter", "病历肾功能信息与布洛芬医嘱需核对":"Renal history and ibuprofen order require review", "本地知识条目命中多条有效医嘱；需核实是否调整或重复计费。":"The local demo rule matched multiple active orders; check adjustments and possible duplicate charges.", "本地知识条目将病历片段与医嘱关联，不能据此直接认定违规。":"The local demo rule links a clinical note and an order; this alone does not establish a violation.", "核实医嘱状态及时间":"Verify order status and timing", "核对实际给药与收费明细":"Check actual administration and charges", "确认肾功能信息的时效和临床解释":"Verify the timing and clinical meaning of renal information", "核对剂量、实际给药与医保政策口径":"Check dose, administration and insurance policy", "FHIR 已接收":"FHIR received", "临床资源已路由":"Clinical resources routed", "审核事件已登记":"Audit event registered", "审核事件已分发":"Audit event dispatched", "就诊上下文已汇集":"Encounter context assembled", "本地知识与病历证据已检索":"Local knowledge and clinical evidence retrieved", "风险已送人工复核":"Findings sent for human review", "人工复核已记录":"Human review recorded"
};
let interfaceLanguage = "zh";
const originalTextNodes = new WeakMap(), originalAttributes = new WeakMap();
/** Translate UI text and limited formatted labels while preserving original policy text and user input. */
function translateInterfaceText(text) {
  if (interfaceLanguage !== "en") return text;
  const trimmed = text.trim(); if (!trimmed) return text;
  if (englishText[trimmed]) return text.replace(trimmed, englishText[trimmed]);
  let result = text;
  result = result.replace(/已接收 (\d+) \/ 3 条合成事件。/g, "Accepted $1 / 3 synthetic events.");
  result = result.replace(/处理进程最近心跳：/g, "Worker last heartbeat: ").replace(/ · (上传中|排队中|向量化中|已导入|处理失败) · (\d+) 个片段 · 待核实/g, (_, state, count) => ` · ${{"上传中":"Uploading","排队中":"Queued","向量化中":"Vectorizing","已导入":"Imported","处理失败":"Failed"}[state]} · ${count} chunks · To verify`).replace(/ · 文件格式、内容或模型长度无效/g, " · Invalid document or content").replace(/ · 模型或 IRIS 处理失败，请检查处理进程/g, " · Model or IRIS processing failed; check the worker");
  result = result.replace(/今日调查次数（UTC）：(\d+) \/ (\d+)；不构成金额预算上限。/g, "Today’s attempts (UTC): $1 / $2; this is not a monetary budget.").replace(/输入 \/ 输出 Token：/g, "Input / output tokens: ").replace(/耗时：/g, "Elapsed: ").replace(/证据引用：/g, "Evidence references: ").replace(/调查未完成：/g, "Investigation incomplete: ").replace(/提交未完成：/g, "Submission incomplete: ").replace(/调查状态不可用：/g, "Investigation status unavailable: ").replace(/；请刷新状态，不会自动重试。/g, "; refresh status; no automatic retry.").replace(/；请人工复核。/g, "; human review required.").replace(/第 (\d+) 页/g, "Page $1").replace(/共 (\d+) 条 · 第 (\d+) \/ (\d+) 页/g, "$1 items · Page $2 / $3")
    .replace(/AI 历史调查：(\d+) 次，模型已启动 (\d+) 次，成功 (\d+) \/ 失败 (\d+)。/g, "Recorded AI investigations: $1; model started: $2; succeeded: $3 / failed: $4.")
    .replace(/已记录用量（(\d+) 次）：输入 (\d+) \/ 输出 (\d+) Token。/g, "Recorded usage ($1 runs): $2 input / $3 output tokens.")
    .replace(/已记录平均耗时（(\d+) 次）：([\d.]+) 秒。/g, "Recorded average duration ($1 runs): $2 seconds.")
    .replace(/MCP 历史调用：(\d+)；服务(已开启|已关闭)，网关(可连通|不可连通)。/g, (_, count, service, gateway) => `MCP calls: ${count}; service ${service === "已开启" ? "enabled" : "disabled"}, gateway ${gateway === "可连通" ? "reachable" : "unreachable"}.`)
    .replace(/采样时间：/g, "Sampled at: ").replace(/；统计的是接口当前返回的合成数据。/g, "; figures reflect synthetic data currently returned by the APIs.")
    .replace(/演示案例 · (\d+) 条疑点/g, "Demo case · $1 findings")
    .replace(/知识库共 (\d+) 条虚构演示依据 · /g, "Knowledge base: $1 fictional demo evidence snippets · ")
    .replace(/处置历史（(\d+)）/g, "Review history ($1)")
    .replace(/统计时间：/g, "Updated: ").replace(/；范围：当前加载的合成案例，按疑点状态统计。/g, "; scope: loaded synthetic cases, grouped by finding status.")
    .replace(/部分案例详情不可用，疑点统计不完整。/g, "Some case details are unavailable; finding counts are incomplete.");
  if (trimmed.startsWith("已检索，待核实 · ")) result = result.replace("已检索，待核实", "Retrieved; verification required");
  result = result.replace("仅为虚构演示依据，非真实医保政策；不能用于违规认定或临床决策。", "Fictional demonstration evidence, not an insurance policy; it cannot establish violations or guide clinical decisions.").replace("没有有效药品医嘱，未启动演示检索。", "No active medication orders; demonstration retrieval was not triggered.").replace("演示向量检索当前不可用。", "Demonstration vector retrieval is unavailable.");
  result = result.replace("仅按药品医嘱关联国家政策，不代表已发生超量开药或医保违规；还需核实处方数量、实际用药、长处方及合理备药等例外。", "Policy evidence is linked to medication orders only. It does not establish excess prescribing or a violation; verify quantities, actual use and relevant exceptions.")
    .replace("没有有效药品医嘱，未启动该场景的政策检索。", "No active medication orders; policy retrieval was not triggered.")
    .replace("未检索到该政策的匹配片段，需人工查阅原文。", "No matching policy excerpt was found; review the source manually.")
    .replace("演示向量检索当前不可用，请检查样例数据。", "National policy retrieval is unavailable; review the source manually.");
  // Replace only known system-generated stage names, preserving node identifiers and timestamps.
  if (trimmed.startsWith("处理阶段：")) for (const stage of ["FHIR 已接收", "临床资源已路由", "审核事件已登记", "审核事件已分发", "就诊上下文已汇集", "本地知识与病历证据已检索", "风险已送人工复核", "人工复核已记录"]) result = result.replaceAll(stage, englishText[stage]);
  const phrases = {"调查 #":"Investigation #","版本 ":"Version ","事件：":"Event: ","事件处理失败：":"Event processing failed: ","状态：":"Status: ","模型：":"Model: ","未配置":"Not configured","来源：":"Source: ","就诊：":"Encounter: ","就诊 ID：":"Encounter ID: ","接收：":"Received: ","尝试次数：":"Attempts: ","失败原因：":"Error: ","处理阶段：":"Stages: ","演示规则 · ":"Demo rule · "," · 版本 ":" · Version ","关联医嘱：":"Related order: ","发布日期：":"Published: ","生效日期：":"Effective: ","相似度 ":"Similarity ","虚构演示（非真实政策）":"National (conditions require verification)","适用范围：":"Scope: ","适用条件：":"Conditions: ","例外：":"Exceptions: ","文号：":"Document no.: ","业务审核：":"Business review: ","测试样例：":"Test cases: ","政策正文":"Policy", "政策附件":"Attachment", "补充资料":"Supplement", "关联政策":"Related policy", "核查标记：":"Review flags: ","演示依据检索：":"National policy retrieval: ","历史状态不可用":"Historical status unavailable", "已被新事件取代":"Superseded", "审核失败":"Audit failed", "处理成功":"Succeeded", "处理失败":"Failed", "排队中":"Queued", "处理中":"Processing", "待复核":"Pending review", "待核查":"Needs review", "已确认":"Confirmed", "已排除":"Dismissed", "待补充":"Not provided", "待核实":"To verify", "待核":"Unverified"};
  for (const [zh, en] of Object.entries(phrases)) result = result.replaceAll(zh, en);
  return result;
}
/** Preserve original labels and translate new DOM nodes without changing policy sources, raw evidence, form values, or embedded IRIS pages. */
function translateInterfaceNode(node) {
  if (node.nodeType === Node.TEXT_NODE) {
    const parent = node.parentElement;
    if (!parent || parent.closest("#page-mcp-tokens, #page-ai-settings, textarea, script, style, #policyEvidence article, .evidence, .agent-output, #reviewRecord, .risk-card details p, #uploadSearchResults .upload-source-content")) return;
    // Preserve policy titles, excerpts, and rule text; translate known field labels only.
    if (parent.closest("#policyList article") && !/^(发布日期|生效日期|核查标记|适用范围|适用条件|例外|来源|文号|业务审核|测试样例)：/.test(node.data.trim()) && !parent.classList.contains("risk-meta")) return;
    let saved = originalTextNodes.get(node);
    if (!saved || (node.data !== saved.last && node.data !== saved.original)) saved = {original: node.data, last: node.data};
    const value = translateInterfaceText(saved.original); saved.last = value; originalTextNodes.set(node, saved);
    if (node.data !== value) node.data = value;
  } else if (node.nodeType === Node.ELEMENT_NODE) {
    if (node.matches("#page-mcp-tokens, #page-ai-settings, iframe, textarea, script, style")) return;
    for (const name of ["placeholder", "aria-label", "title"]) if (node.hasAttribute(name)) {
      let saved = originalAttributes.get(node) || {}; const value = node.getAttribute(name);
      if (!saved[name] || (value !== saved[name].last && value !== saved[name].original)) saved[name] = {original: value, last: value};
      const translated = translateInterfaceText(saved[name].original); saved[name].last = translated; originalAttributes.set(node, saved);
      if (value !== translated) node.setAttribute(name, translated);
    }
    for (const child of node.childNodes) translateInterfaceNode(child);
  }
}
/** Retranslate DOM labels on language changes without regenerating fixtures or clearing unsaved forms. */
function setInterfaceLanguage(language) {
  interfaceLanguage = language === "en" ? "en" : "zh";
  try { localStorage.setItem("med-audit-language", interfaceLanguage); } catch (_) { /* Keep the selection for this session if storage is unavailable. */ }
  document.documentElement.lang = interfaceLanguage === "en" ? "en" : "zh-CN";
  document.title = interfaceLanguage === "en" ? "Medical Insurance Audit · Local Demo" : "医保智能审核 · 本地演示";
  translateInterfaceNode(document.body);
  window.medManagementLanguage?.();
  $("languageToggle").textContent = interfaceLanguage === "en" ? "中文" : "English";
  $("languageToggle").setAttribute("aria-label", interfaceLanguage === "en" ? "切换至中文" : "Switch to English");
}
/** Observe asynchronous UI updates so pagination, statuses, and event lists follow the selected language. */
function initLanguage() {
  try { interfaceLanguage = localStorage.getItem("med-audit-language") === "en" ? "en" : "zh"; } catch (_) { interfaceLanguage = "zh"; }
  const observer = new MutationObserver((records) => { for (const record of records) {
    if (record.type === "characterData") translateInterfaceNode(record.target);
    else for (const node of record.addedNodes) translateInterfaceNode(node);
  } });
  observer.observe(document.body, {subtree: true, childList: true, characterData: true});
  $("languageToggle").addEventListener("click", () => setInterfaceLanguage(interfaceLanguage === "en" ? "zh" : "en"));
  setInterfaceLanguage(interfaceLanguage);
}

initLanguage();
init();

/** Show upload task status and the latest worker heartbeat without claiming failed imports succeeded. */
async function loadUploads() {
  try {
    const data = await api("api/uploads");
    const box = $("uploadJobs"); box.replaceChildren();
    $("uploadWorker").textContent = data.workerHeartbeat ? `处理进程最近心跳：${formatIrisTime(data.workerHeartbeat)}` : "处理进程尚未连接，请检查本地启动脚本。";
    if (!data.jobs.length) { box.textContent = "暂无导入记录。"; return; }
    const labels = {UPLOADING:"上传中", QUEUED:"排队中", RUNNING:"向量化中", SUCCEEDED:"已导入", FAILED:"处理失败"};
    for (const job of paginate("uploads", data.jobs, loadUploads)) {
      const row = el("div", null, "case-row");
      row.append(el("strong", job.filename), el("span", ` · ${labels[job.state] || job.state} · ${job.chunks} 个片段 · 待核实${job.error ? " · " + (job.error === "INVALID_DOCUMENT" ? "文件格式、内容或模型长度无效" : "模型或 IRIS 处理失败，请检查处理进程") : ""}`));
      box.append(row);
    }
  } catch (error) { $("uploadJobs").textContent = `加载失败：${error.message}`; }
}
/** Send fixed-size Base64 chunks and never interpret filenames as paths in the browser or server. */
async function uploadFile(event) {
  event.preventDefault();
  const file = $("uploadFile").files[0], status = $("uploadStatus"), button = $("uploadSubmit");
  if (!file || file.size < 1 || file.size > 2 * 1024 * 1024) { status.textContent = "请选择不超过 2 MB 的非空文件。"; return; }
  button.disabled = true; status.textContent = "正在上传…";
  try {
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = ""; for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
    const encoded = btoa(binary), partSize = 60000, parts = Math.ceil(encoded.length / partSize);
    const post = body => ({method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(body)});
    const job = await api("api/uploads", post({filename:file.name, size:file.size, parts}));
    for (let index = 0; index < parts; index++) await api(`api/uploads/${job.id}/chunk`, post({index, data:encoded.slice(index * partSize, (index + 1) * partSize)}));
    await api(`api/uploads/${job.id}/submit`, post({}));
    status.textContent = "已提交，等待本地向量化。"; $("uploadForm").reset(); await loadUploads();
  } catch (error) { status.textContent = `上传失败：${error.message}`; }
  finally { button.disabled = false; }
}
/** Search the upload vector library; all filenames and body text are rendered as text nodes to avoid executing uploaded content. */
async function searchUploadedDocuments(event) {
  event.preventDefault();
  const query = $("uploadSearchQuery").value.trim();
  const status = $("uploadSearchStatus"), results = $("uploadSearchResults"), button = $("uploadSearchSubmit");
  results.replaceChildren();
  if (!query) { status.textContent = "请输入检索内容。"; return; }
  button.disabled = true;
  status.textContent = "正在检索上传文档…";
  try {
    const response = await api("api/uploads/search", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({query})});
    if (response.status !== "OK" || !Array.isArray(response.items)) throw new Error("返回结果不可用。");
    if (!response.items.length) { status.textContent = "未找到匹配的上传文档。"; return; }
    for (const item of response.items) {
      const card = el("article", undefined, "risk-card");
      const title = el("h3", item.filename || "", "upload-source-content");
      const excerpt = el("p", item.excerpt || "", "upload-source-content");
      const details = el("p", undefined, "hint");
      const score = item.score == null ? NaN : Number(item.score);
      for (const [label, value] of [["任务编号", item.jobId], ["片段序号", item.chunkIndex], ["相似度", Number.isFinite(score) ? score.toFixed(4) : "—"], ["模型指纹", item.modelHash]]) {
        details.append(el("span", label), document.createTextNode(`: ${value ?? "—"} · `));
      }
      card.append(el("div", "上传内容 · 待人工核实", "risk-meta"), title, excerpt, details);
      results.append(card);
    }
    status.textContent = "检索完成，结果仅供人工核实。";
  } catch (error) {
    status.textContent = error.message === "UPLOAD_QUERY_INVALID" ? "查询内容无效或超过模型长度限制。" : "检索失败，请检查服务状态。";
    // Render service errors as text only; avoid interpreting uploaded or abnormal content as HTML.
    if (error.message) results.append(el("p", error.message, "hint upload-source-content"));
  } finally { button.disabled = false; }
}
$("uploadSearchForm").addEventListener("submit", searchUploadedDocuments);
$("uploadForm").addEventListener("submit", uploadFile);
$("uploadRefresh").addEventListener("click", loadUploads);
// Refresh automatically only on the vector library page to show background processing progress.
setInterval(() => { if (location.hash === "#uploads") loadUploads(); }, 5000);

// Page upload records are independent of document vectorization; status is actually updated by the IRIS file Adapter.
let fhirFileRows = [], selectedFHIRFile = "", fhirFileFingerprint = "", fhirFileLoading = false;
const fhirFileLabels = {QUEUED:"等待 Adapter", PROCESSING:"文件处理中", SERVICE_RECEIVED:"业务服务已接收", PROCESSED:"Adapter 已接收处理", DUPLICATE:"重复文件", FAILED:"文件处理失败"};

/** Upload a UTF-8 file; atomic delivery is done server-side and file content is not kept in the browser. */
async function submitFHIRFile(event) {
  event.preventDefault();
  const file = $("fhirFileInput").files[0], status = $("fhirFileStatus"), button = $("fhirFileSubmit");
  if (!file || !file.name.toLowerCase().endsWith(".json") || file.size === 0 || file.size > 1048576) { status.textContent = "请选择不超过 1 MiB 的 JSON 文件。"; return; }
  button.disabled = true; status.textContent = "正在上传…";
  try {
    let content;
    try { content = new TextDecoder("utf-8", {fatal:true}).decode(await file.arrayBuffer()); }
    catch (_) { throw new Error("文件不是有效的 UTF-8 文本。"); }
    const result = await api("api/fhir-files", {method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:file.name,content})});
    selectedFHIRFile = result.id; fhirFileFingerprint = ""; $("fhirFileInput").value = "";
    status.textContent = "上传成功，等待文件 Adapter。"; pageState.fhirFiles = 1; await loadFHIRFiles();
  } catch (error) { status.textContent = error.message; }
  finally { button.disabled = false; }
}

/** Fetch real status; stop polling after leaving the page. */
async function loadFHIRFiles() {
  if (fhirFileLoading) return;
  fhirFileLoading = true;
  try { const result = await api("api/fhir-files"); fhirFileRows = Array.isArray(result.files) ? result.files : []; renderFHIRFiles(); }
  catch (error) { $("fhirFileList").textContent = error.message; }
  finally { fhirFileLoading = false; }
}

/** Render file metadata with text nodes to avoid treating filenames as HTML. */
function renderFHIRFiles() {
  const box = $("fhirFileList"); box.replaceChildren();
  for (const row of paginate("fhirFiles", fhirFileRows, renderFHIRFiles)) {
    const item = el("div", undefined, "dashboard-event"), info = el("div"), actions = el("div", undefined, "actions");
    const meta = el("small"); meta.append(el("span", fhirFileLabels[row.status] || row.status), document.createTextNode(` · ${formatIrisTime(row.createdAt)} · ${row.eventId || "—"}`));
    info.append(el("strong", row.name), meta);
    const show = el("button", "查看文件流程", "secondary"); show.type="button"; show.addEventListener("click",()=>{selectedFHIRFile=row.id;fhirFileFingerprint="";renderFHIRFileFlow();}); actions.append(show);
    if (row.event && row.event.encounterId) { const link=el("a", "查看案例 →"); link.href=`#detail/${encodeURIComponent(row.event.encounterId)}`; actions.append(link); }
    item.append(info,actions); box.append(item);
  }
  if (!fhirFileRows.length) box.append(el("p", "暂无文件处理记录。", "empty"));
  renderFHIRFileFlow();
}

/** Combine file records with recorded business stages of the same event; never infer calls that did not happen. */
function renderFHIRFileFlow() {
  const row = fhirFileRows.find(item => item.id === selectedFHIRFile), panel = $("fhirFileFlowPanel");
  panel.hidden = !row; if (!row) return;
  const fingerprint = JSON.stringify(row); if (fingerprint === fhirFileFingerprint) return; fhirFileFingerprint = fingerprint;
  $("fhirFileStatus").textContent = fhirFileLabels[row.status] || row.status;
  $("fhirFileFlowInfo").replaceChildren(document.createTextNode(row.name + " · "), el("span", fhirFileLabels[row.status] || row.status), document.createTextNode(" · "), el("span", row.event ? (eventStatusLabels[row.event.status] || row.event.status) : "等待事件记录"));
  const stages = [{name:"文件已上传",node:"FHIR File Upload",at:row.createdAt}];
  // File status is shown as actually recorded; rescanning never fabricates new processing nodes.
  for (const entry of row.history || []) stages.push({name:fhirFileLabels[entry.status] || entry.status,node:entry.status === "SERVICE_RECEIVED" ? "FHIRFileService" : "FHIRFileAdapter",at:entry.at});
  // Business stages use historical records; the intake node is a generic name and must not impersonate the file message's real source.
  if (row.event && Array.isArray(row.event.stages)) stages.push(...row.event.stages.map(stage => stage.node === "FHIRIntake" ? {...stage,node:"业务接收记录"} : stage));
  // Processing completion happens after business dispatch; sort by actual recorded time, not concatenation order.
  const stamp = value => { const p=String(value || "").split(","); return p.length === 2 ? Number(p[0])*86400 + Number(p[1]) : 0; };
  stages.sort((a,b) => stamp(a.at) - stamp(b.at));
  window.medFlow.renderFlow($("fhirFileFlow"), {stages,status:row.status === "FAILED" ? "FAILED" : (row.event?.status || row.status),historyAvailable:true,attempts:row.event?.attempts || 0}, formatIrisTime);
}
$("fhirFileForm").addEventListener("submit", submitFHIRFile);
$("fhirFileRefresh").addEventListener("click", loadFHIRFiles);
setInterval(() => { if (location.hash === "#fhir-files") loadFHIRFiles(); }, 2500);
