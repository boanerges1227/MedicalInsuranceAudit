Class HD.AgentOperation Extends Ens.BusinessOperation
{
/// Call AI Hub from a Production component; record failures separately without changing human decisions or insurance settlement.
Method OnMessage(request As HD.Request, Output response As HD.Reply) As %Status
{
    set response=##class(HD.Reply).%New()
    set runId=0,claimed=0
    try {
        set req={}.%FromJSON(request.Payload),runId=+req.%Get("runId",0)
        if runId { set claimed=##class(HD.AgentRequest).Claim(runId,req.encounterId,req.eventId,req.version) }
        if runId,'claimed { set result={"status":"FAILED","error":"AGENT_DUPLICATE_MESSAGE"} }
        else { set result=##class(HD.Agent).Run(req.encounterId,req.eventId,req.version,"",runId) }
    } catch ex { set result={"status":"FAILED","error":"AGENT_PROCESS_ERROR"} }
    if claimed { do ##class(HD.AgentRequest).Finish(runId,result) }
    set response.Payload=result.%ToJSON()
    quit 1
}
}
