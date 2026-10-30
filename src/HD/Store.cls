Class HD.Store Extends %RegisteredObject
{
/// Extract a unique encounter ID from the Bundle and enforce the demo's supported FHIR input scope.
ClassMethod EncounterId(bundle As %DynamicObject) As %String
{
    if bundle.%Get("resourceType","")'="Bundle" { throw ##class(%Exception.General).%New("FHIR_BUNDLE_REQUIRED") }
    if bundle.%Get("type","")'="collection" { throw ##class(%Exception.General).%New("FHIR_COLLECTION_REQUIRED") }
    if 'bundle.%IsDefined("entry") { throw ##class(%Exception.General).%New("FHIR_ENTRY_REQUIRED") }
    set id="",entries=bundle.entry
    for i=0:1:entries.%Size()-1 {
        set resource=entries.%Get(i).resource
        if resource.%Get("resourceType","")="Encounter" {
            if id'="" { throw ##class(%Exception.General).%New("ONE_ENCOUNTER_REQUIRED") }
            set id=resource.%Get("id","")
        }
    }
    if (id="")!($length(id)>64)!($find(id,"/")) { throw ##class(%Exception.General).%New("ENCOUNTER_ID_INVALID") }
    quit id
}

/// Persist raw FHIR resources and audit events in IRIS; return existing results for duplicate Bundle IDs.
ClassMethod Route(bundle As %DynamicObject) As %DynamicObject
{
    set encounterId=..EncounterId(bundle),eventId=bundle.%Get("id","")
    if (eventId="")!($length(eventId)>64)!($find(eventId,"/")) { throw ##class(%Exception.General).%New("BUNDLE_ID_INVALID") }
    // Bundle IDs are globally unique across encounters; lock the event before the encounter to prevent concurrent mapping overwrites.
    lock +^HDData("eventLock",eventId):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    lock +^HDData("lock",encounterId):5
    if '$test { lock -^HDData("eventLock",eventId) throw ##class(%Exception.General).%New("BUSY") }
    try {
        if $data(^HDData("event",eventId)) {
            if ^HDData("event",eventId)'=encounterId { throw ##class(%Exception.General).%New("BUNDLE_ID_CONFLICT") }
            if $get(^HDData("payload",eventId))'=bundle.%ToJSON() { throw ##class(%Exception.General).%New("BUNDLE_ID_CONFLICT") }
            set result={}.%FromJSON(^HDData("case",encounterId))
            if result.eventId'=eventId { set result={"encounterId":(encounterId),"eventId":(eventId),"status":"SUPERSEDED","duplicate":true} }
            else { set result.duplicate=1 }
        } else {
            // Under the encounter lock, block a new event from overwriting a pending-sync audit; replaying the same Bundle still takes the idempotent branch above.
            if $data(^HDData("case",encounterId)) {
                set existing={}.%FromJSON(^HDData("case",encounterId))
                if ##class(HD.Workflow).HasPendingIntent(existing.%Get("eventId","")) { throw ##class(%Exception.General).%New("WORKFLOW_SYNC_PENDING") }
            }
            set txStarted=0,count=0,entries=bundle.entry
            if entries.%Size()>100 { throw ##class(%Exception.General).%New("TOO_MANY_RESOURCES") }
            kill seen
            for i=0:1:entries.%Size()-1 {
                set resource=entries.%Get(i).resource,type=resource.%Get("resourceType",""),id=resource.%Get("id","")
                if (type="")!(id="")!($length(type)>64)!($length(id)>64) { throw ##class(%Exception.General).%New("FHIR_RESOURCE_INVALID") }
                if $data(seen(type,id)) { throw ##class(%Exception.General).%New("FHIR_RESOURCE_DUPLICATE") }
                set seen(type,id)=1
                if resource.%IsDefined("encounter") {
                    if resource.encounter.%Get("reference","")'=("Encounter/"_encounterId) { throw ##class(%Exception.General).%New("ENCOUNTER_REFERENCE_MISMATCH") }
                }
                // Accept numeric versions only under the demo convention; do not invent ordering for unversioned legacy data.
                set v="" if resource.%IsDefined("meta") { set v=resource.meta.%Get("versionId","") }
                if (v'="")&&((v'?1.N)!($length(v)>9)) { throw ##class(%Exception.General).%New("FHIR_VERSION_INVALID") }
                set oldv=$get(^HDData("resourceVersion",encounterId,type,id),"")
                if (oldv'="")&&(v="") { throw ##class(%Exception.General).%New("RESOURCE_VERSION_REQUIRED") }
                if (oldv'="")&&(v'="") {
                    if +v<+oldv { throw ##class(%Exception.General).%New("STALE_RESOURCE_VERSION") }
                    if (+v=+oldv)&&($get(^HDData("resource",encounterId,type,id))'=resource.%ToJSON()) { throw ##class(%Exception.General).%New("RESOURCE_VERSION_CONFLICT") }
                }
                set count=count+1
            }
            // Validate the complete Bundle before atomically writing resources and pending events to avoid partial state on failure.
            tstart
            set txStarted=1
            for i=0:1:entries.%Size()-1 {
                set resource=entries.%Get(i).resource,type=resource.resourceType,id=resource.id
                set ^HDData("resource",encounterId,type,id)=resource.%ToJSON()
                set v="" if resource.%IsDefined("meta") { set v=resource.meta.%Get("versionId","") }
                if v'="" { set ^HDData("resourceVersion",encounterId,type,id)=v }
            }
            set oldVersion=0
            if $data(^HDData("case",encounterId)) { set old={}.%FromJSON(^HDData("case",encounterId)),oldVersion=old.%Get("version",0) }
            set stages=[]
            do stages.%Push({"name":"FHIR 已接收","at":($ztimestamp),"node":"FHIRIntake"})
            do stages.%Push({"name":"临床资源已路由","at":($ztimestamp),"node":"FHIRRoute"})
            do stages.%Push({"name":"审核事件已登记","at":($ztimestamp),"node":"FHIRProcess"})
            set result={"encounterId":(encounterId),"eventId":(eventId),"version":(oldVersion+1),"status":"PROCESSING","resourceCount":(count),"stages":(stages),"risks":[],"engine":"local-retrieval-demo","modelCalled":false,"duplicate":false}
            // Commit the event ledger with the case so accepted events remain visible for recovery before queue dispatch.
            if $data(^HDData("case",encounterId)) {
                set prior={}.%FromJSON(^HDData("case",encounterId)),priorId=prior.%Get("eventId","")
                if $data(^HDData("auditEvent",priorId)) { set pe={}.%FromJSON(^HDData("auditEvent",priorId)),pe.status="SUPERSEDED",pe.updatedAt=$ztimestamp,^HDData("auditEvent",priorId)=pe.%ToJSON() }
            }
            set ev={"eventId":(eventId),"encounterId":(encounterId),"status":"QUEUED","attempts":0,"lastError":"","receivedAt":($ztimestamp),"updatedAt":($ztimestamp)}
            set ^HDData("case",encounterId)=result.%ToJSON(),^HDData("event",eventId)=encounterId,^HDData("payload",eventId)=bundle.%ToJSON(),^HDData("auditEvent",eventId)=ev.%ToJSON()
            // Save the new event and its workflow requirement in one transaction; keep the legacy behavior for old events without the marker.
            set ^HDWorkflow("required",eventId)=encounterId
            tcommit
            set txStarted=0
        }
    } catch ex { if $get(txStarted,0) { trollback } lock -^HDData("lock",encounterId) lock -^HDData("eventLock",eventId) throw ex }
    lock -^HDData("lock",encounterId)
    lock -^HDData("eventLock",eventId)
    quit result
}

/// Read encounter resources, run knowledge retrieval, and persist findings and message stages.
ClassMethod Analyze(eventId As %String, encounterId As %String) As %DynamicObject
{
    lock +^HDData("lock",encounterId):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        if '$data(^HDData("case",encounterId)) { throw ##class(%Exception.General).%New("CASE_NOT_FOUND") }
        set txStarted=0,result={}.%FromJSON(^HDData("case",encounterId))
        if result.eventId'=eventId { throw ##class(%Exception.General).%New("EVENT_MISMATCH") }
        set stages=result.stages
        do stages.%Push({"name":"就诊上下文已汇集","at":($ztimestamp),"node":"AuditEvent"})
        set result.risks=##class(HD.KB).Retrieve(encounterId)
        // Treat synthetic retrieval as separate reference evidence; a medication order alone does not establish excessive quantity.
        set policy=##class(HD.PolicyEvidence).Retrieve(encounterId),result.policyEvidence=policy.items
        do policy.%Remove("items") set result.policyRetrieval=policy
        do stages.%Push({"name":"本地知识与病历证据已检索","at":($ztimestamp),"node":"AuditEvent"})
        do stages.%Push({"name":("演示依据检索："_policy.status),"at":($ztimestamp),"node":"AuditEvent"})
        // Reflect retrieval unavailability in event status instead of reporting audit success.
        set result.status=$select(policy.status="UNAVAILABLE":"AUDIT_FAILED",1:"PENDING_REVIEW")
        do stages.%Push({"name":($select(policy.status="UNAVAILABLE":"政策检索不可用，需人工处理",1:"风险已送人工复核")),"at":($ztimestamp),"node":"AuditEvent"})
        // Commit case results and event status together so monitoring cannot report success without stored results.
        tstart
            set txStarted=1
        set ^HDData("case",encounterId)=result.%ToJSON()
        if $data(^HDData("auditEvent",eventId)) {
            set e={}.%FromJSON(^HDData("auditEvent",eventId)),e.status=$select(policy.status="UNAVAILABLE":"FAILED",1:"SUCCEEDED"),e.lastError=$select(policy.status="UNAVAILABLE":"POLICY_RETRIEVAL_UNAVAILABLE",1:""),e.updatedAt=$ztimestamp
            set ^HDData("auditEvent",eventId)=e.%ToJSON()
        }
        tcommit
            set txStarted=0
    } catch ex { if $get(txStarted,0) { trollback } lock -^HDData("lock",encounterId) throw ex }
    lock -^HDData("lock",encounterId)
    quit result
}

/// Get complete encounter audit status for displaying findings, evidence, and processing history.
ClassMethod Detail(encounterId As %String) As %DynamicObject
{
    if '$data(^HDData("case",encounterId)) { throw ##class(%Exception.General).%New("CASE_NOT_FOUND") }
    quit {}.%FromJSON(^HDData("case",encounterId))
}

/// List encounter summaries in the current demo instance.
ClassMethod List() As %DynamicObject
{
    set cases=[],id=""
    for {
        set id=$order(^HDData("case",id)) quit:id=""
        set c={}.%FromJSON(^HDData("case",id))
        do cases.%Push({"encounterId":(id),"eventId":(c.eventId),"status":(c.status),"riskCount":(c.risks.%Size()),"version":(c.version)})
    }
    quit {"cases":(cases)}
}

/// Reject stale case-level reviews using the version and record the human decision and reason.
ClassMethod Review(encounterId As %String, input As %DynamicObject) As %DynamicObject
{
    set decision=input.%Get("decision",""),reason=input.%Get("reason",""),reviewer=input.%Get("reviewer","")
    if (decision'="NEEDS_CHECK")&&(decision'="CONFIRMED")&&(decision'="DISMISSED") { throw ##class(%Exception.General).%New("DECISION_INVALID") }
    if (reason="")!($length(reason)>500)!(reviewer="")!($length(reviewer)>80) { throw ##class(%Exception.General).%New("REVIEW_FIELDS_REQUIRED") }
    lock +^HDData("lock",encounterId):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=..Detail(encounterId)
        if c.version'=input.%Get("version",0) { throw ##class(%Exception.General).%New("VERSION_CONFLICT") }
        if c.status="PROCESSING" { throw ##class(%Exception.General).%New("AUDIT_NOT_READY") }
        // A case with no findings can be closed; with findings, all tasks must be complete and none pending sync.
        if $data(^HDWorkflow("required",c.eventId)),'##class(HD.Workflow).CanCloseCase(c) { throw ##class(%Exception.General).%New("WORKFLOW_REQUIRED") }
        set c.version=c.version+1,c.status=decision
        set c.review={"reviewer":(reviewer),"decision":(decision),"reason":(reason),"at":($ztimestamp)}
        do c.stages.%Push({"name":"人工复核已记录","at":($ztimestamp),"node":(reviewer)})
        set ^HDData("case",encounterId)=c.%ToJSON()
    } catch ex { lock -^HDData("lock",encounterId) throw ex }
    lock -^HDData("lock",encounterId)
    quit c
}
}
