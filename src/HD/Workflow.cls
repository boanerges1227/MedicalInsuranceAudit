Class HD.Workflow Extends %RegisteredObject
{
/// Create the demo reviewer role and users; idempotent across restarts and concurrent calls.
ClassMethod EnsureRole()
{
    lock +^HDWorkflow("setup"):5 if '$test { throw ##class(%Exception.General).%New("WORKFLOW_BUSY") }
    try {
        if '##class(EnsLib.Workflow.RoleDefinition).%ExistsId("MedicalAuditReviewer") {
            set sc=##class(EnsLib.Workflow.RoleDefinition).CreateRole("MedicalAuditReviewer")
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        }
        // Configure native workflow identity only for the two known local demo admins; never auto-grant other accounts.
        for user="medreview","_SYSTEM" {
            if '##class(EnsLib.Workflow.UserDefinition).%ExistsId(user) {
                set sc=##class(EnsLib.Workflow.UserDefinition).CreateUser(user)
                if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            }
            if '##class(EnsLib.Workflow.RoleMembership).%ExistsId("MedicalAuditReviewer||"_user) {
                set sc=##class(EnsLib.Workflow.RoleDefinition).AddUserToRole("MedicalAuditReviewer",user)
                if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            }
            set ^HDWorkflow("member",user)=1
        }
    } catch ex { lock -^HDWorkflow("setup") throw ex }
    lock -^HDWorkflow("setup")
}

/// Dispatch each event and finding only once; keep state when the outcome is unknown instead of auto-resending.
ClassMethod EnqueueCase(host As %RegisteredObject, c As %DynamicObject)
{
    if c.%Get("status","")'="PENDING_REVIEW" { quit }
    do ..EnsureRole()
    set event=c.eventId,encounter=c.encounterId
    for i=0:1:c.risks.%Size()-1 {
        set risk=c.risks.%Get(i),finding=risk.%Get("id","")
        if finding="" { continue }
        lock +^HDWorkflow("event",event):5 if '$test { throw ##class(%Exception.General).%New("WORKFLOW_BUSY") }
        set reserving=0
        try {
            if '$data(^HDWorkflow("finding",event,finding)) {
                // Reserve the unique mapping and dispatch intent in one transaction to avoid a half-written mapping on interruption.
                tstart
                set reserving=1
                set id=$increment(^HDWorkflow("counter")),subject="HDWF-"_id
                set ^HDWorkflow("finding",event,finding)=id
                set ^HDWorkflow("task",id)={"taskId":(+id),"encounterId":(encounter),"eventId":(event),"findingId":(finding),"findingVersion":0,"subject":(subject),"dispatchState":"DISPATCHING"}.%ToJSON()
                tcommit
                set reserving=0
                set task=##class(EnsLib.Workflow.TaskRequest).%New(),task.%Subject=subject,task.%Message="Synthetic medical audit finding",task.%Actions="CONFIRMED,DISMISSED"
                set sc=host.SendRequestAsync("MedicalAuditReviewer",task,0)
                set record={}.%FromJSON(^HDWorkflow("task",id))
                if $system.Status.IsError(sc) { set record.dispatchState="FAILED",^HDWorkflow("task",id)=record.%ToJSON() throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
                set record.dispatchState="QUEUED",^HDWorkflow("task",id)=record.%ToJSON()
            }
        } catch ex { if reserving { trollback } lock -^HDWorkflow("event",event) throw ex }
        lock -^HDWorkflow("event",event)
    }
}

/// Query the task response; return an empty value when not found so queued or failed states are shown truthfully.
ClassMethod Native(subject As %String) As %RegisteredObject
{
    set st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT %ID AS id FROM EnsLib_Workflow.TaskResponse WHERE %Subject = ? ORDER BY %ID DESC")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    set rs=st.%Execute(subject)
    if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("WORKFLOW_QUERY_FAILED") }
    if 'rs.%Next() { quit "" }
    quit ##class(EnsLib.Workflow.TaskResponse).%OpenId(rs.%Get("id"))
}

/// Treat the business review as complete only when the native completion action matches the finding's review history.
ClassMethod NativeMatchesReview(row As %DynamicObject, native As %RegisteredObject) As %Boolean
{
    if '$isobject(native) { quit 0 }
    if 'native.%TaskStatus.IsComplete { quit 0 }
    set action=native.%Action,assignee=native.%TaskStatus.AssignedTo
    if (action'="CONFIRMED")&&(action'="DISMISSED") { quit 0 }
    if assignee="" { quit 0 }
    set version=+row.%Get("findingVersion",0)+1
    if +$get(^HDData("finding",row.encounterId,row.eventId,row.findingId,"version"),0)'=version { quit 0 }
    set raw=$get(^HDData("finding",row.encounterId,row.eventId,row.findingId,"history",version))
    if raw="" { quit 0 }
    set record=""
    try { set record={}.%FromJSON(raw) } catch ex { set record="" }
    if '$isobject(record) { quit 0 }
    if (record.%Get("version",-1)'=version)!(record.%Get("decision","")'=action)!(record.%Get("reviewer","")'=assignee) { quit 0 }
    if $zstrip(record.%Get("reason",""),"<>W")="" { quit 0 }
    quit 1
}

/// Under the encounter lock, check whether the current event has a review intent that is not yet reconciled.
ClassMethod HasPendingIntent(eventId As %String) As %Boolean
{
    set finding="",pending=0
    for {
        set finding=$order(^HDWorkflow("finding",eventId,finding)) quit:finding=""
        set id=$get(^HDWorkflow("finding",eventId,finding))
        if (id'="")&&$data(^HDWorkflow("intent",id)) { set pending=1 quit }
    }
    quit pending
}

/// Extract the summary from findings of the same event; never borrow current-case content when missing or stale.
ClassMethod FindingSummary(row As %DynamicObject, c As %DynamicObject) As %DynamicObject
{
    set summary={}
    if row.%Get("eventId","")'=c.%Get("eventId","") { quit summary }
    set risks=c.%Get("risks","")
    if '$isobject(risks) { quit summary }
    if 'risks.%IsA("%DynamicArray") { quit summary }
    for i=0:1:risks.%Size()-1 {
        set risk=risks.%Get(i)
        if '$isobject(risk) { continue }
        if risk.%Get("id","")'=row.%Get("findingId","") { continue }
        set summary={"title":($extract(risk.%Get("title",""),1,160)),"explanation":($extract(risk.%Get("explanation",""),1,400)),"level":($extract(risk.%Get("level",""),1,40))}
        quit
    }
    quit summary
}

/// Return workflow status and the finding summary of the same event; never return raw FHIR data.
ClassMethod List() As %DynamicObject
{
    set out=[],id=""
    for { set id=$order(^HDWorkflow("task",id),-1) quit:id=""  quit:out.%Size()'<100
        set row={}.%FromJSON(^HDWorkflow("task",id)),native=..Native(row.subject)
        set row.status=row.dispatchState,row.assignee="",row.nativeTaskId="",row.syncPending=$data(^HDWorkflow("intent",id))>0
        if $isobject(native) { set row.nativeTaskId=native.%Id(),row.assignee=native.%TaskStatus.AssignedTo,row.status=$select(native.%TaskStatus.IsComplete:"COMPLETED",row.assignee'="":"CLAIMED",1:"AVAILABLE") }
        if $isobject(native),native.%TaskStatus.IsComplete,'row.syncPending,'..NativeMatchesReview(row,native) { set row.status="REVIEW_MISMATCH" }
        if row.syncPending { set row.status="SYNC_PENDING" }
        set row.stale=0,row.findingSummary={}
        try {
            set c=##class(HD.Store).Detail(row.encounterId)
            if c.eventId'=row.eventId { set row.stale=1 }
            else { set row.findingSummary=..FindingSummary(row,c) }
        } catch ex { set row.stale=1 }
        do out.%Push(row)
    }
    quit {"tasks":(out),"dispatchErrors":(..DispatchErrors())}
}

/// Check the current event for missing or uncertain dispatch outcomes; never misreport unknown outcomes as retryable.
ClassMethod DispatchErrors() As %DynamicArray
{
    set out=[],event=""
    for {
        set event=$order(^HDWorkflow("required",event)) quit:event=""  quit:out.%Size()'<100
        set encounter=$get(^HDWorkflow("required",event)),missing=0,uncertain=0,error=$get(^HDWorkflow("error",event)),current=0
        try { set c=##class(HD.Store).Detail(encounter) if (c.eventId=event)&&(c.status="PENDING_REVIEW") { set current=1 } } catch ignored { }
        if 'current { continue }
        for i=0:1:c.risks.%Size()-1 {
            set finding=c.risks.%Get(i).%Get("id","") if finding="" { continue }
            set taskId=$get(^HDWorkflow("finding",event,finding))
            if taskId="" { set missing=missing+1 continue }
            if '$data(^HDWorkflow("task",taskId)) { set uncertain=uncertain+1 continue }
            set t={}.%FromJSON(^HDWorkflow("task",taskId))
            // Queued without a task yet may still be processing or may have failed asynchronously; always show it as to-verify.
            if ((t.dispatchState="FAILED")!(t.dispatchState="DISPATCHING")!(t.dispatchState="QUEUED")),'$isobject(..Native(t.subject)) { set uncertain=uncertain+1 }
        }
        if missing!uncertain!(error'="") {
            set code=$select(uncertain>0:"WORKFLOW_DISPATCH_UNCERTAIN",missing>0:"WORKFLOW_DISPATCH_MISSING",1:"WORKFLOW_DISPATCH_ERROR")
            do out.%Push({"eventId":(event),"encounterId":(encounter),"error":(code),"missingCount":(missing),"uncertainCount":(uncertain),"lastError":(error)})
        }
    }
    quit out
}

/// Validate tasks and sync state for all findings of a case; a case with no findings can be closed manually.
ClassMethod CanCloseCase(c As %DynamicObject) As %Boolean
{
    if 'c.%IsDefined("risks") { quit 0 }
    if c.risks.%Size()=0 { quit 1 }
    set event=c.eventId
    if $get(^HDWorkflow("error",event))'="" { quit 0 }
    set ok=1
    for i=0:1:c.risks.%Size()-1 {
        set finding=c.risks.%Get(i).%Get("id","")
        if finding="" { set ok=0 quit }
        set id=$get(^HDWorkflow("finding",event,finding))
        if (id="")!('$data(^HDWorkflow("task",id)))!$data(^HDWorkflow("intent",id)) { set ok=0 quit }
        set record={}.%FromJSON(^HDWorkflow("task",id)),native=..Native(record.subject)
        if '$isobject(native) { set ok=0 quit }
        if '..NativeMatchesReview(record,native) { set ok=0 quit }
    }
    quit ok
}

/// Re-dispatch only findings of the current event that have no mapping yet; never resend dispatched or uncertain ones.
ClassMethod RetryDispatch(eventId As %String) As %DynamicObject
{
    if '$data(^HDWorkflow("required",eventId)) { throw ##class(%Exception.General).%New("WORKFLOW_EVENT_NOT_FOUND") }
    set encounter=^HDWorkflow("required",eventId),c=##class(HD.Store).Detail(encounter)
    if c.eventId'=eventId { throw ##class(%Exception.General).%New("EVENT_MISMATCH") }
    if c.status'="PENDING_REVIEW" { throw ##class(%Exception.General).%New("AUDIT_NOT_READY") }
    // When every issue is an unknown dispatch outcome, never claim retry success or blindly resend.
    set issues=..DispatchErrors()
    for i=0:1:issues.%Size()-1 {
        set issue=issues.%Get(i)
        if (issue.eventId=eventId)&&(issue.missingCount=0)&&(issue.uncertainCount>0) { throw ##class(%Exception.General).%New("WORKFLOW_DISPATCH_UNCERTAIN") }
    }
    set sc=##class(Ens.Director).CreateBusinessService("FHIRIntake",.service)
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    set sc=service.RetryWorkflow(eventId,.result)
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    quit result
}

/// Validate the task and current event version; reject operations on stale tasks.
ClassMethod Resolve(id As %String) As %DynamicObject
{
    if id'?1.N { throw ##class(%Exception.General).%New("WORKFLOW_NOT_FOUND") }
    if '$data(^HDWorkflow("task",id)) { throw ##class(%Exception.General).%New("WORKFLOW_NOT_FOUND") }
    set row={}.%FromJSON(^HDWorkflow("task",id)),c=##class(HD.Store).Detail(row.encounterId)
    if c.eventId'=row.eventId { throw ##class(%Exception.General).%New("EVENT_MISMATCH") }
    quit row
}

/// Verify on every operation that the current user is still an active member of the reviewer role.
ClassMethod RequireMember(user As %String)
{
    if '$isobject(##class(EnsLib.Workflow.UserDefinition).%OpenId(user)) { throw ##class(%Exception.General).%New("WORKFLOW_FORBIDDEN") }
    set account=##class(EnsLib.Workflow.UserDefinition).%OpenId(user)
    if 'account.IsActive { throw ##class(%Exception.General).%New("WORKFLOW_FORBIDDEN") }
    if '##class(EnsLib.Workflow.RoleMembership).%ExistsId("MedicalAuditReviewer||"_user) { throw ##class(%Exception.General).%New("WORKFLOW_FORBIDDEN") }
}

/// Claim the task as the actual signed-in user; role permission is verified by the workflow engine.
ClassMethod Claim(id As %String, user As %String) As %DynamicObject
{
    do ..RequireMember(user)
    lock +^HDWorkflow("taskLock",id):5 if '$test { throw ##class(%Exception.General).%New("WORKFLOW_BUSY") }
    try {
        set row=..Resolve(id),native=..Native(row.subject)
        if '$isobject(native) { throw ##class(%Exception.General).%New("WORKFLOW_NOT_READY") }
        if native.%TaskStatus.IsComplete { throw ##class(%Exception.General).%New("WORKFLOW_COMPLETED") }
        if (native.%TaskStatus.AssignedTo'="")&&(native.%TaskStatus.AssignedTo'=user) { throw ##class(%Exception.General).%New("WORKFLOW_ASSIGNED") }
        if native.%TaskStatus.AssignedTo="" {
            set count=0,sc=native.AssignTask(user,.count)
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            if count<1 { throw ##class(%Exception.General).%New("WORKFLOW_NOT_ASSIGNED") }
        }
        set result={"taskId":(+id),"status":"CLAIMED","assignee":(user)}
    } catch ex { lock -^HDWorkflow("taskLock",id) throw ex }
    lock -^HDWorkflow("taskLock",id)
    quit result
}

/// Coordinate review records with the native workflow via persisted intent; repeated requests safely resume an unfinished sync.
ClassMethod Complete(id As %String, user As %String, input As %DynamicObject) As %DynamicObject
{
    do ..RequireMember(user)
    lock +^HDWorkflow("taskLock",id):5 if '$test { throw ##class(%Exception.General).%New("WORKFLOW_BUSY") }
    set encounter="",locked=0
    try {
        set row=..Resolve(id),encounter=row.encounterId
        lock +^HDData("lock",encounter):5 if '$test { throw ##class(%Exception.General).%New("BUSY") }
        set locked=1,row=..Resolve(id),native=..Native(row.subject)
        if '$isobject(native) { throw ##class(%Exception.General).%New("WORKFLOW_NOT_READY") }
        if native.%TaskStatus.AssignedTo'=user { throw ##class(%Exception.General).%New("WORKFLOW_NOT_OWNER") }
        if input.%Get("eventId","")'=row.eventId { throw ##class(%Exception.General).%New("EVENT_MISMATCH") }
        set decision=input.%Get("decision",""),reason=input.%Get("reason",""),version=input.%Get("version",-1)
        if (decision'="CONFIRMED")&&(decision'="DISMISSED") { throw ##class(%Exception.General).%New("DECISION_INVALID") }
        if ($zstrip(reason,"<>W")="")!($length(reason)>500) { throw ##class(%Exception.General).%New("REVIEW_FIELDS_REQUIRED") }
        if version'?1.N { throw ##class(%Exception.General).%New("VERSION_CONFLICT") }
        set intent={"eventId":(row.eventId),"version":(+version),"decision":(decision),"reason":(reason),"reviewer":(user)}
        if $data(^HDWorkflow("intent",id)) {
            set old={}.%FromJSON(^HDWorkflow("intent",id))
            if (old.eventId'=intent.eventId)!(old.version'=intent.version)!(old.decision'=intent.decision)!(old.reason'=intent.reason)!(old.reviewer'=user) { throw ##class(%Exception.General).%New("WORKFLOW_SYNC_PENDING") }
        } else {
            if native.%TaskStatus.IsComplete { throw ##class(%Exception.General).%New("WORKFLOW_COMPLETED") }
            if +$get(^HDData("finding",encounter,row.eventId,row.findingId,"version"),0)'=version { throw ##class(%Exception.General).%New("VERSION_CONFLICT") }
            set ^HDWorkflow("intent",id)=intent.%ToJSON()
        }
        // The native completion call has its own transaction, so record intent first, then check history to avoid duplicate writes on retry.
        set next=version+1,history=$get(^HDData("finding",encounter,row.eventId,row.findingId,"history",next))
        if history="" {
            set review={"eventId":(row.eventId),"version":(+version),"decision":(decision),"reason":(reason),"reviewer":(user)}
            try { set c=##class(HD.Finding).Review(encounter,row.findingId,review,1) }
            catch reviewError { if '$data(^HDData("finding",encounter,row.eventId,row.findingId,"history",next)) { kill ^HDWorkflow("intent",id) } throw reviewError }
        } else {
            set previous={}.%FromJSON(history)
            if (previous.decision'=decision)!(previous.reason'=reason)!(previous.reviewer'=user) { throw ##class(%Exception.General).%New("WORKFLOW_SYNC_CONFLICT") }
        }
        if 'native.%TaskStatus.IsComplete {
            set sc=native.CompleteTask(decision)
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            // The native API mutates the object and sends the response; save explicitly before clearing the sync intent.
            set sc=native.%Save()
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        } else {
            if native.%Action'=decision { throw ##class(%Exception.General).%New("WORKFLOW_SYNC_CONFLICT") }
        }
        kill ^HDWorkflow("intent",id)
        set c=##class(HD.Finding).AnnotateLocked(##class(HD.Store).Detail(encounter))
        set result={"taskId":(+id),"status":"COMPLETED","case":(c)}
    } catch ex { if locked { lock -^HDData("lock",encounter) } lock -^HDWorkflow("taskLock",id) throw ex }
    if locked { lock -^HDData("lock",encounter) }
    lock -^HDWorkflow("taskLock",id)
    quit result
}
/// Resume sync using only the persisted intent; never overwrite a saved human decision with new parameters.
ClassMethod Retry(id As %String, user As %String) As %DynamicObject
{
    do ..RequireMember(user)
    if id'?1.N { throw ##class(%Exception.General).%New("WORKFLOW_NOT_FOUND") }
    if '$data(^HDWorkflow("intent",id)) { throw ##class(%Exception.General).%New("WORKFLOW_NO_PENDING_SYNC") }
    set intent={}.%FromJSON(^HDWorkflow("intent",id))
    if intent.reviewer'=user { throw ##class(%Exception.General).%New("WORKFLOW_NOT_OWNER") }
    quit ..Complete(id,user,intent)
}

}
