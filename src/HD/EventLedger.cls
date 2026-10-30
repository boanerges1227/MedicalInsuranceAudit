Class HD.EventLedger Extends %RegisteredObject
{
/// Mark processing as started under the encounter lock; stale or duplicate work must not overwrite newer events.
ClassMethod Start(eventId As %String, encounterId As %String) As %Boolean
{
    lock +^HDData("lock",encounterId):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        if '$data(^HDData("auditEvent",eventId)) { throw ##class(%Exception.General).%New("EVENT_NOT_FOUND") }
        set e={}.%FromJSON(^HDData("auditEvent",eventId)),go=0
        if e.status="QUEUED" {
            set c=##class(HD.Store).Detail(encounterId)
            if c.eventId'=eventId { set e.status="SUPERSEDED",e.updatedAt=$ztimestamp }
            else { set e.status="RUNNING",e.attempts=e.attempts+1,e.updatedAt=$ztimestamp,go=1 }
            set ^HDData("auditEvent",eventId)=e.%ToJSON()
        }
    } catch ex { lock -^HDData("lock",encounterId) throw ex }
    lock -^HDData("lock",encounterId)
    quit go
}

/// Record audit failure without changing a case superseded by a later event.
ClassMethod Fail(eventId As %String, encounterId As %String, reason As %String, queuedOnly As %Boolean = 0)
{
    lock +^HDData("lock",encounterId):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        if $data(^HDData("auditEvent",eventId)) {
            set e={}.%FromJSON(^HDData("auditEvent",eventId)),c=##class(HD.Store).Detail(encounterId)
            // Dispatch failures may update only waiting events, without overwriting an audit another worker has already started.
            if (e.status="QUEUED")!((e.status="RUNNING")&&'queuedOnly) {
                tstart
                if c.eventId'=eventId { set e.status="SUPERSEDED" }
                else { set e.status="FAILED",c.status="AUDIT_FAILED",^HDData("case",encounterId)=c.%ToJSON() }
                set e.lastError=$extract(reason,1,120),e.updatedAt=$ztimestamp,^HDData("auditEvent",eventId)=e.%ToJSON()
                tcommit
            }
        }
    } catch ex { if $tlevel { trollback } lock -^HDData("lock",encounterId) throw ex }
    lock -^HDData("lock",encounterId)
}

/// Allow manual redispatch of the current failed or waiting event; reject running or stale events.
ClassMethod Retry(eventId As %String) As %DynamicObject
{
    if '$data(^HDData("event",eventId)) { throw ##class(%Exception.General).%New("EVENT_NOT_FOUND") }
    set encounterId=^HDData("event",eventId)
    lock +^HDData("lock",encounterId):5
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        if '$data(^HDData("auditEvent",eventId)) { throw ##class(%Exception.General).%New("EVENT_NOT_FOUND") }
        set e={}.%FromJSON(^HDData("auditEvent",eventId)),c=##class(HD.Store).Detail(encounterId)
        if ((e.status'="FAILED")&&(e.status'="QUEUED"))!(c.eventId'=eventId) { throw ##class(%Exception.General).%New("EVENT_NOT_RETRYABLE") }
        tstart
        set e.status="QUEUED",e.lastError="",e.updatedAt=$ztimestamp,c.status="PROCESSING"
        set ^HDData("auditEvent",eventId)=e.%ToJSON(),^HDData("case",encounterId)=c.%ToJSON()
        tcommit
    } catch ex { if $tlevel { trollback } lock -^HDData("lock",encounterId) throw ex }
    lock -^HDData("lock",encounterId)
    quit e
}
}
