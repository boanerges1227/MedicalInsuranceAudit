Class HD.AgentOperation Extends Ens.BusinessOperation
{
/// Call AI Hub from a Production component; record failures separately without changing human decisions or insurance settlement.
Method OnMessage(request As HD.Request, Output response As HD.Reply) As %Status
{
    new %HDTraceContext
    set %HDTraceContext=""
    set response=##class(HD.Reply).%New()
    set runId=0,claimed=0
    try {
        set req={}.%FromJSON(request.Payload),runId=+req.%Get("runId",0)
        if runId { set claimed=##class(HD.AgentRequest).Claim(runId,req.encounterId,req.eventId,req.version) }
        if runId,'claimed { set result={"status":"FAILED","error":"AGENT_DUPLICATE_MESSAGE"} }
        else {
            set %HDTraceContext=##class(HD.Trace.Scope).Start($this,runId,req.eventId,req.version,..%SessionId)
            set result=##class(HD.Agent).Run(req.encounterId,req.eventId,req.version,"",runId)
        }
    } catch ex { set result={"status":"FAILED","error":"AGENT_PROCESS_ERROR"} }
    if $isobject(%HDTraceContext) {
        do %HDTraceContext.Finish(result.%Get("status","")="VALIDATED")
        if %HDTraceContext.Failed {
            // Retain actual invocation/accounting metadata while withholding the untraceable recommendation.
            set result={"status":"FAILED","error":"TRACE_FAILED","modelStarted":(result.%Get("modelStarted",0)),"model":(result.%Get("model","")),"usage":(result.%Get("usage",{})),"elapsedSeconds":(result.%Get("elapsedSeconds",0)),"eventId":(req.eventId),"caseVersion":(req.version)}
        }
        set result=##class(HD.Agent).Publish(req.encounterId,req.eventId,req.version,result)
    }
    if claimed { do ##class(HD.AgentRequest).Finish(runId,result) }
    set response.Payload=result.%ToJSON()
    quit 1
}
}
