Class HD.WorkflowDispatch Extends Ens.BusinessOperation
{
/// Rebuild missing workflow tasks for the current event and record errors for the page to view and retry.
Method OnMessage(request As HD.Request, Output response As HD.Reply) As %Status
{
    set response=##class(HD.Reply).%New(),event=""
    try {
        set event={}.%FromJSON(request.Payload).%Get("eventId","")
        if '$data(^HDWorkflow("required",event)) { throw ##class(%Exception.General).%New("WORKFLOW_EVENT_NOT_FOUND") }
        set c=##class(HD.Store).Detail(^HDWorkflow("required",event))
        if c.eventId'=event { throw ##class(%Exception.General).%New("EVENT_MISMATCH") }
        do ##class(HD.Workflow).EnqueueCase($this,c)
        kill ^HDWorkflow("error",event)
        set result={"eventId":(event),"status":"DISPATCHED"}
    } catch ex {
        if event'="" { set ^HDWorkflow("error",event)=ex.Name }
        set result={"error":(ex.Name)}
    }
    set response.Payload=result.%ToJSON()
    quit 1
}
}
