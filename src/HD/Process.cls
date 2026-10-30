Class HD.Process Extends Ens.BusinessProcess
{
/// Dispatch audits asynchronously after accepting clinical resources; audit failures do not roll back accepted FHIR events.
Method OnRequest(request As HD.Request, Output response As HD.Reply) As %Status
{
    set response=##class(HD.Reply).%New()
    try {
        set route=##class(HD.Request).%New(),route.Payload=request.Payload
        set status=..SendRequestSync("FHIRRoute",route,.routeReply,30)
        if $system.Status.IsError(status) { throw ##class(%Exception.StatusException).CreateFromStatus(status) }
        set routed={}.%FromJSON(routeReply.Payload)
        if routed.%IsDefined("error") { throw ##class(%Exception.General).%New(routed.error) }
        // Return existing status for duplicate events without redispatching; failed events require the explicit retry endpoint.
        if 'routed.%Get("duplicate",0) {
            set audit=##class(HD.Request).%New(),audit.Payload={"eventId":(routed.eventId),"encounterId":(routed.encounterId)}.%ToJSON()
            set status=..SendRequestAsync("AuditEvent",audit,0)
            if $system.Status.IsError(status) {
                do ##class(HD.EventLedger).Fail(routed.eventId,routed.encounterId,"AUDIT_DISPATCH_FAILED",1)
                set routed.status="AUDIT_FAILED"
            }
        }
        set result=routed
    } catch ex { set result={"error":(ex.Name)} }
    set response.Payload=result.%ToJSON()
    quit 1
}
}
