Class HD.Audit Extends Ens.BusinessOperation
{
/// Audit events in a separate queue; record errors in the event ledger without blocking FHIR intake.
Method OnMessage(request As HD.Request, Output response As HD.Reply) As %Status
{
    set response=##class(HD.Reply).%New(),event=""
    try {
        set event={}.%FromJSON(request.Payload)
        if ##class(HD.EventLedger).Start(event.eventId,event.encounterId) {
            set result=##class(HD.Store).Analyze(event.eventId,event.encounterId)
            // Record workflow errors separately; never disguise a completed synthetic audit as a failure.
            try { do ##class(HD.Workflow).EnqueueCase($this,result) } catch workflowError { set ^HDWorkflow("error",event.eventId)=workflowError.Name }
        }
        else { set result={"status":"SKIPPED"} }
    } catch ex {
        if $isobject(event) { try { do ##class(HD.EventLedger).Fail(event.eventId,event.encounterId,ex.Name) } catch ignored { } }
        set result={"error":(ex.Name)}
    }
    set response.Payload=result.%ToJSON()
    quit 1
}
}
