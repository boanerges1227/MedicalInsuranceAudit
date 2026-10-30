Class HD.AgentRequest Extends %RegisteredObject
{
/// Count daily attempts by UTC date; enqueueing consumes an attempt without automatic refunds for failures or timeouts.
ClassMethod Day() As %Integer { quit +$piece($ztimestamp,",",1) }
/// Return the global shared limit for AI investigation attempts per UTC day.
ClassMethod Limit() As %Integer { quit 50 }

/// Register investigations serially, validate the current case and event, and reject concurrent or excessive requests.
ClassMethod Reserve(encounterId As %String, data As %DynamicObject) As %DynamicObject
{
    do ##class(HD.AdminSession).Require()
    if (data.%GetTypeOf("eventId")'="string")!(data.%GetTypeOf("version")'="number") { throw ##class(%Exception.General).%New("AGENT_INPUT_INVALID") }
    set eventId=data.eventId,version=data.version
    if (eventId="")!(version<1)!(version\1'=version) { throw ##class(%Exception.General).%New("AGENT_INPUT_INVALID") }
    lock +^HDData("agentQueueLock"):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        lock +^HDData("lock",encounterId):5
        if '$test { throw ##class(%Exception.General).%New("BUSY") }
        try {
            set c=##class(HD.Store).Detail(encounterId)
            if (c.eventId'=eventId)!(c.version'=version) { throw ##class(%Exception.General).%New("STALE_CASE") }
            if (c.status="PROCESSING")!(c.status="AUDIT_FAILED") { throw ##class(%Exception.General).%New("CASE_NOT_READY") }
            if +$get(^HDData("agentActive"))>0 { throw ##class(%Exception.General).%New("AGENT_ALREADY_RUNNING") }
            set day=..Day(),used=+$get(^HDData("agentDaily",day))
            if used'<..Limit() { throw ##class(%Exception.General).%New("AGENT_DAILY_LIMIT") }
            set runId=$increment(^HDData("agentRunSeq")),job={"runId":(runId),"encounterId":(encounterId),"eventId":(eventId),"caseVersion":(version),"status":"QUEUED","createdAt":($ztimestamp),"requestedBy":($username)}
            tstart
            set ^HDData("agentRuns",runId)=job.%ToJSON(),^HDData("agentLast",encounterId,eventId,version)=runId,^HDData("agentActive")=runId,^HDData("agentDaily",day)=used+1
            tcommit
        } catch ex { if $tlevel { trollback } lock -^HDData("lock",encounterId) throw ex }
        lock -^HDData("lock",encounterId)
    } catch ex { lock -^HDData("agentQueueLock") throw ex }
    lock -^HDData("agentQueueLock")
    quit job
}

/// Claim only the matching queued task so duplicate messages cannot restart the model.
ClassMethod Claim(runId As %Integer, encounterId As %String, eventId As %String, version As %Integer) As %Boolean
{
    lock +^HDData("agentQueueLock"):5
    if '$test { quit 0 }
    set raw=$get(^HDData("agentRuns",runId)),claimed=0
    if raw'="" {
        set job={}.%FromJSON(raw)
        if (+$get(^HDData("agentActive"))=runId)&&(job.status="QUEUED")&&(job.encounterId=encounterId)&&(job.eventId=eventId)&&(job.caseVersion=version) {
            set job.status="RUNNING",job.startedAt=$ztimestamp,^HDData("agentRuns",runId)=job.%ToJSON(),claimed=1
        }
    }
    lock -^HDData("agentQueueLock")
    quit claimed
}

/// Complete only the matching task; record failures separately without overwriting human review.
ClassMethod Finish(runId As %Integer, result As %DynamicObject)
{
    lock +^HDData("agentQueueLock"):5
    if '$test { quit }
    set raw=$get(^HDData("agentRuns",runId))
    if raw'="" {
        set job={}.%FromJSON(raw)
        if (job.status="QUEUED")!(job.status="RUNNING") {
            set job.status=$select(result.%Get("status","")="VALIDATED":"SUCCEEDED",1:"FAILED"),job.result=result,job.finishedAt=$ztimestamp
            set ^HDData("agentRuns",runId)=job.%ToJSON()
            if +$get(^HDData("agentActive"))=runId { kill ^HDData("agentActive") }
        }
    }
    lock -^HDData("agentQueueLock")
}

/// Record only fixed stages actually reached by this worker; exclude model output, clinical records, and credentials.
ClassMethod TraceSafe(runId As %Integer, kind As %String)
{
    if 'runId { quit }
    if '$listfind($listfromstring("MODEL_STARTED,CASE_EVIDENCE,POLICY_EVIDENCE,OUTPUT_VALIDATED"),kind) { quit }
    // Tracing is auxiliary; recording failures must not interrupt the audit workflow.
    try {
        lock +^HDData("agentQueueLock"):2
        if '$test { quit }
        try {
            set raw=$get(^HDData("agentRuns",runId))
            if raw'="" {
                set job={}.%FromJSON(raw)
                // Prevent mismatched execution context from writing traces to another investigation.
                if (job.status="RUNNING")&&(job.encounterId=$get(^HDData("agentContext",$job,"encounter")))&&(job.eventId=$get(^HDData("agentContext",$job,"event")))&&(job.caseVersion=+$get(^HDData("agentContext",$job,"version"))) {
                    set n=$increment(^HDData("agentTrace",runId,"next")),^HDData("agentTrace",runId,n)={"kind":(kind),"at":($ztimestamp)}.%ToJSON()
                }
            }
        } catch ex { set ignored=1 }
        lock -^HDData("agentQueueLock")
    } catch ex { set ignored=1 }
}

/// Return investigation records for the current event and the global quota; do not assume unfinished tasks have failed.
ClassMethod Status(encounterId As %String, eventId As %String, version As %Integer) As %DynamicObject
{
    set run=+$get(^HDData("agentLast",encounterId,eventId,version)),job={}
    if run,$data(^HDData("agentRuns",run)) { set job={}.%FromJSON(^HDData("agentRuns",run)) }
    set trace=[],n=0
    if run for  { set n=$order(^HDData("agentTrace",run,n)) quit:'n  do trace.%Push({}.%FromJSON(^HDData("agentTrace",run,n))) }
    quit {"trace":(trace),"eventId":(eventId),"caseVersion":(version),"job":(job),"dailyUsed":(+$get(^HDData("agentDaily",..Day()))),"dailyLimit":(..Limit()),"active":(+$get(^HDData("agentActive"))>0),"quotaTimezone":"UTC"}
}
}
