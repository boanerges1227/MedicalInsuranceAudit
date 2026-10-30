Class HD.REST Extends %CSP.REST
{
Parameter CHARSET = "utf-8";
Parameter HandleCorsRequest = 0;
Parameter UseSession As Integer = 1;
XData UrlMap
{
<Routes>
  <Route Url="/" Method="GET" Call="Index"/>
  <Route Url="/app.js" Method="GET" Call="Script"/>
  <Route Url="/flow.js" Method="GET" Call="FlowScript"/>
  <Route Url="/style.css" Method="GET" Call="Style"/>
  <Route Url="/sample.json" Method="GET" Call="Sample"/>
  <Route Url="/settings" Method="GET" Call="SettingsPage"/>
  <Route Url="/settings.js" Method="GET" Call="SettingsScript"/>
  <Route Url="/mcp-tokens" Method="GET" Call="MCPTokenPage"/>
  <Route Url="/mcp-tokens.js" Method="GET" Call="MCPTokenScript"/>
  <Route Url="/mcp-tokens.css" Method="GET" Call="MCPTokenStyle"/>
  <Route Url="/login" Method="GET" Call="LoginPage"/>
  <Route Url="/visit-stats" Method="GET" Call="VisitStats"/>
  <Route Url="/login.js" Method="GET" Call="LoginScript"/>
  <Route Url="/login.css" Method="GET" Call="LoginStyle"/>
  <Route Url="/admin-session.js" Method="GET" Call="AdminScript"/>
  <Route Url="/management.css" Method="GET" Call="ManagementStyle"/>
  <Route Url="/management-i18n.js" Method="GET" Call="ManagementLanguageScript"/>
  <Route Url="/admin/session" Method="GET" Call="AdminSession"/>
  <Route Url="/admin/login" Method="POST" Call="AdminLogin"/>
  <Route Url="/admin/logout" Method="POST" Call="AdminLogout"/>
  <Route Url="/admin/models" Method="GET" Call="AdminModels"/>
  <Route Url="/admin/models" Method="POST" Call="AdminSaveModel"/>
  <Route Url="/admin/models/:id/activate" Method="POST" Call="AdminActivateModel"/>
  <Route Url="/admin/mcp-tokens" Method="GET" Call="AdminTokens"/>
  <Route Url="/admin/mcp-tokens" Method="POST" Call="AdminCreateToken"/>
  <Route Url="/admin/mcp-tokens/:id" Method="POST" Call="AdminUpdateToken"/>
  <Route Url="/admin/mcp-tokens/:id/revoke" Method="POST" Call="AdminRevokeToken"/>
  <Route Url="/api/health" Method="GET" Call="Health"/>
  <Route Url="/api/agent-summary" Method="GET" Call="AgentSummary"/>
  <Route Url="/api/mcp-status" Method="GET" Call="MCPStatus"/>
  <Route Url="/api/mcp-logs" Method="GET" Call="MCPLogs"/>
  <Route Url="/api/mcp-control" Method="POST" Call="MCPControl"/>
  <Route Url="/api/production-target" Method="GET" Call="ProductionTarget"/>
  <Route Url="/api/uploads/search" Method="POST" Call="UploadSearch"/>
  <Route Url="/api/uploads" Method="GET" Call="UploadList"/>
  <Route Url="/api/uploads" Method="POST" Call="UploadCreate"/>
  <Route Url="/api/uploads/:id/chunk" Method="POST" Call="UploadChunk"/>
  <Route Url="/api/uploads/:id/submit" Method="POST" Call="UploadSubmit"/>
  <Route Url="/api/workflow/events/:eventId/retry" Method="POST" Call="WorkflowDispatchRetry"/>
  <Route Url="/api/workflow/tasks" Method="GET" Call="WorkflowTasks"/>
  <Route Url="/api/workflow/tasks/:id/claim" Method="POST" Call="WorkflowClaim"/>
  <Route Url="/api/workflow/tasks/:id/complete" Method="POST" Call="WorkflowComplete"/>
  <Route Url="/api/workflow/tasks/:id/retry" Method="POST" Call="WorkflowRetry"/>
  <Route Url="/api/knowledge" Method="GET" Call="Knowledge"/>
  <Route Url="/api/cases" Method="GET" Call="Cases"/>
  <Route Url="/api/events" Method="GET" Call="Events"/>
  <Route Url="/api/events/:eventId/retry" Method="POST" Call="RetryEvent"/>
  <Route Url="/api/policies" Method="GET" Call="Policies"/>
  <Route Url="/api/rules" Method="GET" Call="Rules"/>
  <Route Url="/api/cases/:id/findings/:findingId/review" Method="POST" Call="FindingReview"/>
  <Route Url="/api/cases/:id/agent-status" Method="GET" Call="AgentStatus"/>
  <Route Url="/api/cases/:id/investigate" Method="POST" Call="AgentInvestigate"/>
  <Route Url="/api/cases/:id" Method="GET" Call="CaseDetail"/>
  <Route Url="/api/fhir" Method="POST" Call="SubmitFHIR"/>
  <Route Url="/api/fhir-files" Method="GET" Call="FHIRFileList"/>
  <Route Url="/api/fhir-files" Method="POST" Call="FHIRFileSubmit"/>
  <Route Url="/api/cases/:id/review" Method="POST" Call="Review"/>
</Routes>
}

/// Protect business pages and data APIs with IRIS sessions; allow anonymous access only to login and fixed static assets.
ClassMethod OnPreDispatch(pUrl As %String, pMethod As %String, ByRef pContinue As %Boolean) As %Status
{
    set %response.UseHttpOnly=1
    do %response.SetHeader("Cache-Control","no-store")
    set pContinue=1,path=pUrl
    if $extract(path,1)'="/" { set path="/"_path }
    set public=$listfromstring("/login,/visit-stats,/login.js,/login.css,/admin-session.js,/management.css,/management-i18n.js,/admin/login,/admin/logout,/admin/session,/style.css,/app.js,/flow.js,/settings.js,/mcp-tokens.js,/mcp-tokens.css")
    if '$listfind(public,path) {
        set state=##class(HD.AdminSession).Current()
        if 'state.authenticated {
            do ##class(HD.AdminSession).End()
            if (pMethod="GET"),$listfind($listfromstring("/,/settings,/mcp-tokens"),path) {
                set target="/med-audit"_path,%response.Redirect="/med-audit/login?returnTo="_$zconvert(target,"O","URL")
            } else {
                set %response.Status="401 Unauthorized"
                do ..Json({"error":"ADMIN_AUTHENTICATION_REQUIRED"})
            }
            set pContinue=0
        }
    }
    quit 1
}

/// Reuse existing administrator authentication and permission checks within the same application session.
ClassMethod AdminSession() As %Status { quit ##class(HD.AdminREST).Session() }
ClassMethod AdminLogin() As %Status { quit ##class(HD.AdminREST).Login() }
ClassMethod AdminLogout() As %Status { quit ##class(HD.AdminREST).Logout() }
ClassMethod AdminModels() As %Status { quit ##class(HD.AdminREST).Models() }
ClassMethod AdminSaveModel() As %Status { quit ##class(HD.AdminREST).SaveModel() }
ClassMethod AdminActivateModel(id As %String) As %Status { quit ##class(HD.AdminREST).ActivateModel(id) }
ClassMethod AdminTokens() As %Status { quit ##class(HD.AdminREST).Tokens() }
ClassMethod AdminCreateToken() As %Status { quit ##class(HD.AdminREST).CreateToken() }
ClassMethod AdminUpdateToken(id As %String) As %Status { quit ##class(HD.AdminREST).UpdateToken(id) }
ClassMethod AdminRevokeToken(id As %String) As %Status { quit ##class(HD.AdminREST).RevokeToken(id) }

/// Serve static files from the same origin so browsers do not send FHIR data to another port.
ClassMethod Asset(name As %String, mime As %String) As %Status
{
    set %response.ContentType=mime
    do %response.SetHeader("Content-Security-Policy","default-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'")
    set stream=##class(%Stream.FileCharacter).%New(),stream.TranslateTable="UTF8"
    set status=stream.LinkToFile(##class(HD.PackageSetup).Root()_"web/"_name)
    if $system.Status.IsError(status) { return ..RespondError("NOT_FOUND") }
    while 'stream.AtEnd { write stream.Read(32767) }
    return 1
}

/// Return the audit workbench page.
ClassMethod Index() As %Status { return ..Asset("index.html","text/html; charset=utf-8") }
/// Return the browser interaction script.
ClassMethod Script() As %Status { return ..Asset("app.js","application/javascript; charset=utf-8") }
/// Return the business stage playback script without exposing event data.
ClassMethod FlowScript() As %Status { return ..Asset("flow.js","application/javascript; charset=utf-8") }
/// Return the page stylesheet.
ClassMethod Style() As %Status { return ..Asset("style.css","text/css; charset=utf-8") }
/// Return an editable synthetic FHIR R4 encounter fixture.
ClassMethod Sample() As %Status { return ..Asset("sample.json","application/fhir+json; charset=utf-8") }
/// Serve management assets through a fixed file mapping; authenticate sensitive data through administrator APIs.
ClassMethod SettingsPage() As %Status { quit ..Asset("settings.html","text/html; charset=utf-8") }
ClassMethod SettingsScript() As %Status { quit ..Asset("settings.js","application/javascript; charset=utf-8") }
ClassMethod MCPTokenPage() As %Status { quit ..Asset("mcp-tokens.html","text/html; charset=utf-8") }
ClassMethod MCPTokenScript() As %Status { quit ..Asset("mcp-tokens.js","application/javascript; charset=utf-8") }
ClassMethod MCPTokenStyle() As %Status { quit ..Asset("mcp-tokens.css","text/css; charset=utf-8") }
/// Count each successful login page request with an atomic increment for concurrent access.
ClassMethod LoginPage() As %Status
{
    try { set count=$increment(^HDVisitStats($namespace,"total")) } catch ex { set ignored=1 }
    quit ..Asset("login.html","text/html; charset=utf-8")
}
/// Return the cumulative count without incrementing it when statistics are read.
ClassMethod VisitStats() As %Status
{
    try { set count=+$get(^HDVisitStats($namespace,"total")) } catch ex { set %response.Status="503 Service Unavailable" return ..Json({"error":"VISIT_STATS_UNAVAILABLE"}) }
    return ..Json({"total":(count),"metric":"login-page-views"})
}
/// Return the fixed Production entry only to authenticated sessions; read credentials from local private configuration.
ClassMethod ProductionTarget() As %Status
{
    try { set data=##class(HD.ProductionPortal).Target() } catch ex { set %response.Status="503 Service Unavailable" return ..Json({"error":"PRODUCTION_PORTAL_NOT_CONFIGURED"}) }
    do %response.SetHeader("Referrer-Policy","no-referrer")
    return ..Json(data)
}
ClassMethod LoginScript() As %Status { quit ..Asset("login.js","application/javascript; charset=utf-8") }
ClassMethod LoginStyle() As %Status { quit ..Asset("login.css","text/css; charset=utf-8") }
ClassMethod AdminScript() As %Status { quit ..Asset("admin-session.js","application/javascript; charset=utf-8") }
ClassMethod ManagementStyle() As %Status { quit ..Asset("management.css","text/css; charset=utf-8") }
/// Serve management page translations between English and Chinese without changing user input.
ClassMethod ManagementLanguageScript() As %Status { quit ..Asset("management-i18n.js","application/javascript; charset=utf-8") }

/// Return JSON consistently and prevent browser caching of demo patient data.
ClassMethod Json(data As %DynamicAbstractObject) As %Status
{
    set %response.ContentType="application/json; charset=utf-8"
    do %response.SetHeader("Cache-Control","no-store")
    do %response.SetHeader("X-Content-Type-Options","nosniff")
    write data.%ToJSON()
    return 1
}

/// Map expected demo errors to HTTP status codes without exposing stack traces.
ClassMethod RespondError(code As %String) As %Status
{
    set http=400
    if (code="CASE_NOT_FOUND")!(code="FINDING_NOT_FOUND")!(code="EVENT_NOT_FOUND")!(code="WORKFLOW_NOT_FOUND")!(code="WORKFLOW_EVENT_NOT_FOUND") { set http=404 }
    if code="FORBIDDEN" { set http=403 }
    if (code="STALE_CASE")!(code="CASE_NOT_READY")!(code="AGENT_ALREADY_RUNNING")!(code="AGENT_DAILY_LIMIT")!(code="VERSION_CONFLICT")!(code="BUNDLE_ID_CONFLICT")!(code="EVENT_MISMATCH")!(code="HISTORY_CONFLICT")!(code="RESOURCE_VERSION_REQUIRED")!(code="RESOURCE_VERSION_CONFLICT")!(code="STALE_RESOURCE_VERSION")!(code="EVENT_NOT_RETRYABLE") { set http=409 }
    if (code="WORKFLOW_REQUIRED")!(code="WORKFLOW_NOT_READY")!(code="WORKFLOW_COMPLETED")!(code="WORKFLOW_ASSIGNED")!(code="WORKFLOW_NOT_ASSIGNED")!(code="WORKFLOW_SYNC_PENDING")!(code="WORKFLOW_SYNC_CONFLICT")!(code="WORKFLOW_NO_PENDING_SYNC")!(code="WORKFLOW_DISPATCH_UNCERTAIN") { set http=409 }
    if (code="WORKFLOW_NOT_OWNER")!(code="WORKFLOW_FORBIDDEN") { set http=403 }
    if code="WORKFLOW_BUSY" { set http=503 }
    if code="CONTENT_TYPE_REQUIRED" { set http=415 }
    if code="INPUT_TOO_LARGE" { set http=413 }
    if (code="PRODUCTION_UNAVAILABLE")!(code="BUSY")!(code="EMBEDDING_UNAVAILABLE") { set http=503 }
    if $extract(code,1)="<" { set code="INTERNAL_ERROR",http=500 }
    set %response.Status=http_" "_$select(http=403:"Forbidden",http=404:"Not Found",http=409:"Conflict",http=413:"Payload Too Large",http=415:"Unsupported Media Type",http=503:"Service Unavailable",http=500:"Internal Server Error",1:"Bad Request")
    return ..Json({"error":(code)})
}

/// Read size-limited JSON requests and validate the local page header and same-origin source.
ClassMethod Body(limit As %Integer = 131072) As %DynamicObject
{
    if %request.GetCgiEnv("HTTP_X_MED_AUDIT_DEMO")'="local-demo" { throw ##class(%Exception.General).%New("FORBIDDEN") }
    set origin=%request.GetCgiEnv("HTTP_ORIGIN"),host=%request.GetCgiEnv("HTTP_HOST")
    if (origin'="")&&(origin'=("http://"_host)) { throw ##class(%Exception.General).%New("FORBIDDEN") }
    if '$isobject(%request.Content) { throw ##class(%Exception.General).%New("INVALID_JSON") }
    if %request.Content.Size>limit { throw ##class(%Exception.General).%New("INPUT_TOO_LARGE") }
    // Decode the CSP request's UTF-8 bytes explicitly so Chinese review reasons are not stored as Latin-1.
    set raw=%request.Content.Read(limit+1)
    try { set data={}.%FromJSON($zconvert(raw,"I","UTF8")) }
    catch ex { throw ##class(%Exception.General).%New("INVALID_JSON") }
    if 'data.%IsA("%DynamicObject") { throw ##class(%Exception.General).%New("INVALID_JSON") }
    return data
}

/// Re-dispatch only audit tasks with no mapping; never resend tasks whose state is uncertain.
ClassMethod WorkflowDispatchRetry(eventId As %String) As %Status
{
    try { do ##class(HD.AdminSession).Require() set ignored=..Body(),result=##class(HD.Workflow).RetryDispatch(eventId) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Read workflow tasks; identity and permission are determined by the signed-in IRIS session.
ClassMethod WorkflowTasks() As %Status
{
    try { do ##class(HD.AdminSession).Require() set result=##class(HD.Workflow).List() } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Claim the task as the current signed-in user; the assignee cannot be specified via the request body.
ClassMethod WorkflowClaim(id As %String) As %Status
{
    try { do ##class(HD.AdminSession).Require() set ignored=..Body(),result=##class(HD.Workflow).Claim(id,$username) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Save the human decision and coordinate task completion; keep the recovery intent on sync failure.
ClassMethod WorkflowComplete(id As %String) As %Status
{
    try { do ##class(HD.AdminSession).Require() set result=##class(HD.Workflow).Complete(id,$username,..Body()) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Resume a pending-sync task per the server-persisted intent, preventing the caller from altering a saved decision.
ClassMethod WorkflowRetry(id As %String) As %Status
{
    try { do ##class(HD.AdminSession).Require() set ignored=..Body(),result=##class(HD.Workflow).Retry(id,$username) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Retrieve uploaded document vectors after login and same-origin request validation.
ClassMethod UploadSearch() As %Status
{
    try { set result=##class(HD.UploadSearch).Search(..Body()) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Apply the shared login and same-origin checks to uploads and task listings.
ClassMethod UploadList() As %Status { return ..Json(##class(HD.UploadVector).List()) }
ClassMethod UploadCreate() As %Status
{
    try { set result=##class(HD.UploadVector).Create(..Body()) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}
ClassMethod UploadChunk(id As %String) As %Status
{
    try { set result=##class(HD.UploadVector).Append(id,..Body()) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}
ClassMethod UploadSubmit(id As %String) As %Status
{
    try { set ignored=..Body(),result=##class(HD.UploadVector).Submit(id) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Report the actual Production status and retrieval mode.
ClassMethod Health() As %Status
{
    return ..Json({"productionRunning":(##class(Ens.Director).IsProductionRunning()),"engine":"local-retrieval-demo","modelCalled":false})
}

/// Return historical MCP call summaries without claiming current gateway health was probed.
ClassMethod MCPStatus() As %Status { quit ..Json(##class(HD.MCP.Status).Snapshot()) }
/// Return recent tool calls through authenticated cursor pagination without loading all records.
ClassMethod MCPLogs() As %Status
{
    try { set result=##class(HD.MCP.Status).Logs(%request.Get("before")) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}
/// Allow only administrators to control MCP service access.
ClassMethod MCPControl() As %Status
{
    try { set result=##class(HD.MCP.Status).SetEnabled(..Body()) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Return evidence-backed historical AI task statistics without calling the model.
ClassMethod AgentSummary() As %Status
{
    try { set result=##class(HD.AgentMonitor).Summary() } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Show local demo knowledge entries and versions.
ClassMethod Knowledge() As %Status { return ..Json({"entries":(##class(HD.KB).Catalog())}) }
/// List encounter work items stored in IRIS.
ClassMethod Cases() As %Status { return ..Json(##class(HD.Store).List()) }
/// Return findings, FHIR evidence paths, message stages, and review records.
ClassMethod CaseDetail(id As %String) As %Status
{
    try {
        set result=##class(HD.Finding).Annotate(##class(HD.Store).Detail(id)),eventId=result.eventId,version=result.version
        if $data(^HDData("agentResult",id,eventId,version)) { set result.agentReview={}.%FromJSON(^HDData("agentResult",id,eventId,version)) }
    }
    catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Read asynchronous investigation status and call quota for the current event.
ClassMethod AgentStatus(id As %String) As %Status
{
    try { set c=##class(HD.Store).Detail(id),result=##class(HD.AgentRequest).Status(id,c.eventId,c.version) } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}
/// Require an administrator session, the current event version, and the same-origin header to start an investigation.
ClassMethod AgentInvestigate(id As %String) As %Status
{
    try {
        do ##class(HD.AdminSession).Require()
        set body=..Body(),sc=##class(Ens.Director).CreateBusinessService("FHIRIntake",.service)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PRODUCTION_UNAVAILABLE") }
        set sc=service.QueueInvestigation(id,body,.result)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("AGENT_DISPATCH_FAILED") }
    } catch ex { return ..RespondError(ex.Name) }
    set %response.Status="202 Accepted"
    return ..Json(result)
}

/// Return current and historical event summaries without inventing history when old snapshots are missing.
ClassMethod Events() As %Status
{
    try { set result=##class(HD.EventMonitor).List() }
    catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Manually retry the current failed event through controlled dispatch without changing the original FHIR acceptance result.
ClassMethod RetryEvent(eventId As %String) As %Status
{
    try {
        set body=..Body(),status=##class(Ens.Director).CreateBusinessService("FHIRIntake",.service)
        if $system.Status.IsError(status) { throw ##class(%Exception.General).%New("PRODUCTION_UNAVAILABLE") }
        set status=service.Retry(eventId,.result)
        if $system.Status.IsError(status) { throw ##class(%Exception.General).%New("AUDIT_DISPATCH_FAILED") }
    } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Search national policies by keywords read-only; similarity does not establish policy validity.
ClassMethod Policies() As %Status
{
    try { set result=##class(HD.Governance).Policies(%request.Get("query")) }
    catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Read national rule drafts without exposing rule activation.
ClassMethod Rules() As %Status
{
    try { set result=##class(HD.Governance).Rules() }
    catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Record human decisions independently by encounter, event, and finding while rejecting stale versions.
ClassMethod FindingReview(id As %String, findingId As %String) As %Status
{
    try { set body=..Body(),body.reviewer=$username,result=##class(HD.Finding).Review(id,findingId,body) }
    catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Accept page file content, preserving user-session auth and limiting request size.
ClassMethod FHIRFileSubmit() As %Status
{
    try {
        set body=..Body(2097152),result=##class(HD.FHIRFileUI).Submit(body)
    } catch ex { return ..RespondError(ex.Name) }
    set %response.Status="202 Accepted"
    return ..Json(result)
}

/// Return page-uploaded files and their recorded audit flow.
ClassMethod FHIRFileList() As %Status
{
    try { set result=##class(HD.FHIRFileUI).List() } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Accept a FHIR R4 Bundle through the Business Service and both Production Operations.
ClassMethod SubmitFHIR() As %Status
{
    try {
        set contentType=$zconvert($piece(%request.GetCgiEnv("CONTENT_TYPE"),";"),"L")
        if contentType'="application/fhir+json" { throw ##class(%Exception.General).%New("CONTENT_TYPE_REQUIRED") }
        set body=..Body()
        set status=##class(Ens.Director).CreateBusinessService("FHIRIntake",.service)
        if $system.Status.IsError(status) { throw ##class(%Exception.General).%New("PRODUCTION_UNAVAILABLE") }
        set status=service.Submit(body,.result)
        if $system.Status.IsError(status) { throw ##class(%Exception.General).%New("PRODUCTION_UNAVAILABLE") }
        if result.%IsDefined("error") { throw ##class(%Exception.General).%New(result.error) }
    } catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}

/// Write human reviews back to IRIS and require the client to supply the current version.
ClassMethod Review(id As %String) As %Status
{
    try { set body=..Body(),body.reviewer=$username,result=##class(HD.Store).Review(id,body) }
    catch ex { return ..RespondError(ex.Name) }
    return ..Json(result)
}
}
