Class HD.Service Extends Ens.BusinessService
{
Parameter ADAPTER = "";

/// Submit web FHIR Bundles through Production instead of calling business storage directly.
Method Submit(bundle As %DynamicObject, Output result As %DynamicObject) As %Status
{
    set request=##class(HD.Request).%New(),request.Payload=bundle.%ToJSON()
    set status=..SendRequestSync("FHIRProcess",request,.reply,30)
    if $system.Status.IsOK(status) { set result={}.%FromJSON(reply.Payload) }
    quit status
}
/// Manually retry the current failed audit event; affect only the audit branch.
Method Retry(eventId As %String, Output result As %DynamicObject) As %Status
{
    set event=##class(HD.EventLedger).Retry(eventId),request=##class(HD.Request).%New()
    set request.Payload={"eventId":(event.eventId),"encounterId":(event.encounterId)}.%ToJSON()
    set status=..SendRequestAsync("AuditEvent",request,0)
    if $system.Status.IsError(status) {
        do ##class(HD.EventLedger).Fail(event.eventId,event.encounterId,"AUDIT_DISPATCH_FAILED",1)
        throw ##class(%Exception.General).%New("AUDIT_DISPATCH_FAILED")
    }
    set result={"eventId":(event.eventId),"status":"QUEUED"}
    quit 1
}

/// Start an AI Hub investigation from Production for controlled local validation without an anonymous HTTP endpoint.
Method Investigate(encounterId As %String, eventId As %String, version As %Integer, Output result As %DynamicObject) As %Status
{
    set request=##class(HD.Request).%New(),request.Payload={"encounterId":(encounterId),"eventId":(eventId),"version":(version)}.%ToJSON()
    set status=..SendRequestSync("AgentReview",request,.reply,90)
    if $system.Status.IsOK(status) { set result={}.%FromJSON(reply.Payload) }
    quit status
}

/// Dispatch registered workbench investigations to a separate operation queue so HTTP requests do not wait for the model.
Method QueueInvestigation(encounterId As %String, data As %DynamicObject, Output result As %DynamicObject) As %Status
{
    set result=##class(HD.AgentRequest).Reserve(encounterId,data),request=##class(HD.Request).%New()
    set request.Payload={"encounterId":(encounterId),"eventId":(data.eventId),"version":(data.version),"runId":(result.runId)}.%ToJSON()
    set status=..SendRequestAsync("AgentReview",request,0)
    if $system.Status.IsError(status) {
        do ##class(HD.AgentRequest).Finish(result.runId,{"status":"FAILED","error":"AGENT_DISPATCH_FAILED","modelStarted":false})
        throw ##class(%Exception.General).%New("AGENT_DISPATCH_FAILED")
    }
    quit 1
}

/// Re-dispatch missing tasks for the current audit event; repeated requests are deduplicated by the event-level mapping.
Method RetryWorkflow(eventId As %String, Output result As %DynamicObject) As %Status
{
    set req=##class(HD.Request).%New(),req.Payload={"eventId":(eventId)}.%ToJSON()
    set sc=..SendRequestAsync("WorkflowDispatch",req,0)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("WORKFLOW_RETRY_DISPATCH_FAILED") }
    set result={"eventId":(eventId),"status":"QUEUED"}
    quit 1
}

}
