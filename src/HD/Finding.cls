Class HD.Finding Extends %RegisteredObject
{
/// Attach independent review status for the current event to each existing finding without rewriting the original case or legacy case-level reviews.
ClassMethod Annotate(c As %DynamicObject) As %DynamicObject
{
    set encounterId=c.%Get("encounterId","")
    lock +^HDData("lock",encounterId):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try { set c=..AnnotateLocked(c) }
    catch ex { lock -^HDData("lock",encounterId) throw ex }
    lock -^HDData("lock",encounterId)
    quit c
}

/// Read a complete review snapshot while holding the encounter lock.
ClassMethod AnnotateLocked(c As %DynamicObject) As %DynamicObject
{
    set encounterId=c.%Get("encounterId",""),eventId=c.%Get("eventId","")
    if 'c.%IsDefined("risks") { quit c }
    for i=0:1:c.risks.%Size()-1 {
        set risk=c.risks.%Get(i),findingId=risk.%Get("id",""),history=[]
        set version=+$get(^HDData("finding",encounterId,eventId,findingId,"version"),0)
        for n=1:1:version {
            if $data(^HDData("finding",encounterId,eventId,findingId,"history",n)) {
                do history.%Push({}.%FromJSON(^HDData("finding",encounterId,eventId,findingId,"history",n)))
            }
        }
        set status=$get(^HDData("finding",encounterId,eventId,findingId,"status"),"NEEDS_CHECK")
        set risk.findingState={"status":(status),"version":(version),"history":(history)}
    }
    quit c
}

/// Validate event and finding versions under the encounter lock, append immutable review history, and return the complete case.
ClassMethod Review(encounterId As %String, findingId As %String, input As %DynamicObject, fromWorkflow As %Boolean = 0) As %DynamicObject
{
    set decision=input.%Get("decision",""),reason=input.%Get("reason",""),reviewer=input.%Get("reviewer","")
    if (decision'="NEEDS_CHECK")&&(decision'="CONFIRMED")&&(decision'="DISMISSED") { throw ##class(%Exception.General).%New("DECISION_INVALID") }
    if ($zstrip(reason,"<>W")="")!($length(reason)>500)!($zstrip(reviewer,"<>W")="")!($length(reviewer)>80) { throw ##class(%Exception.General).%New("REVIEW_FIELDS_REQUIRED") }
    lock +^HDData("lock",encounterId):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    set txStarted=0
    try {
        set c=##class(HD.Store).Detail(encounterId),eventId=c.%Get("eventId","")
        if (eventId="")!(input.%Get("eventId","")'=eventId) { throw ##class(%Exception.General).%New("EVENT_MISMATCH") }
        if c.status="PROCESSING" { throw ##class(%Exception.General).%New("AUDIT_NOT_READY") }
        // A finding linked to a workflow can only be written through the task-completion entry, preventing bypass of the claim state.
        if 'fromWorkflow,($data(^HDWorkflow("required",eventId))!$data(^HDWorkflow("finding",eventId,findingId))) { throw ##class(%Exception.General).%New("WORKFLOW_REQUIRED") }
        set found=0
        for i=0:1:c.risks.%Size()-1 { if c.risks.%Get(i).%Get("id","")=findingId { set found=1 quit } }
        if 'found { throw ##class(%Exception.General).%New("FINDING_NOT_FOUND") }
        set version=+$get(^HDData("finding",encounterId,eventId,findingId,"version"),0)
        if 'input.%IsDefined("version") { throw ##class(%Exception.General).%New("VERSION_CONFLICT") }
        if input.%Get("version")'=version { throw ##class(%Exception.General).%New("VERSION_CONFLICT") }
        // Key history sequences by event and finding to preserve other findings and older events.
        set next=version+1
        if $data(^HDData("finding",encounterId,eventId,findingId,"history",next)) { throw ##class(%Exception.General).%New("HISTORY_CONFLICT") }
        set record={"version":(next),"decision":(decision),"reason":(reason),"reviewer":(reviewer),"at":($ztimestamp)}
        // Commit history, status, and version in one transaction; roll back all changes on failure.
        tstart
        set txStarted=1
        set ^HDData("finding",encounterId,eventId,findingId,"history",next)=record.%ToJSON()
        set ^HDData("finding",encounterId,eventId,findingId,"status")=decision,^HDData("finding",encounterId,eventId,findingId,"version")=next
        tcommit
        set txStarted=0
        set c=..AnnotateLocked(c)
    } catch ex {
        if txStarted { trollback }
        lock -^HDData("lock",encounterId) throw ex
    }
    lock -^HDData("lock",encounterId)
    quit c
}
}
