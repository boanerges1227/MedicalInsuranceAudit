Class HD.EventMonitor Extends %RegisteredObject
{
/// Show the actual event ledger and latest case stages; explicitly label legacy records without a ledger.
ClassMethod List() As %DynamicObject
{
    set rows=[],eventId=""
    for {
        set eventId=$order(^HDData("event",eventId)) quit:eventId=""
        set encounterId=$get(^HDData("event",eventId)),stage=[],status="HISTORY_UNAVAILABLE",version=0,count=0,attempts=0,lastError="",receivedAt=""
        if $data(^HDData("auditEvent",eventId)) {
            set e={}.%FromJSON(^HDData("auditEvent",eventId)),status=e.%Get("status","HISTORY_UNAVAILABLE"),attempts=e.%Get("attempts",0),lastError=e.%Get("lastError",""),receivedAt=e.%Get("receivedAt","")
        }
        if $data(^HDData("case",encounterId)) {
            set c={}.%FromJSON(^HDData("case",encounterId))
            if c.%Get("eventId","")=eventId {
                set version=c.%Get("version",0),count=c.%Get("resourceCount",0),stage=c.%Get("stages",[])
                if '$data(^HDData("auditEvent",eventId)) { set status=c.%Get("status","UNKNOWN") }
            } elseif '$data(^HDData("auditEvent",eventId)) { set status="SUPERSEDED" }
        }
        do rows.%Push({"eventId":(eventId),"encounterId":(encounterId),"status":(status),"version":(version),"resourceCount":(count),"stages":(stage),"attempts":(attempts),"lastError":(lastError),"receivedAt":(receivedAt),"historyAvailable":((status'="SUPERSEDED")&&(status'="HISTORY_UNAVAILABLE"))})
    }
    quit {"events":(rows),"scope":"仅演示系统已接收事件，旧事件不保留完整病例快照","async":true}
}
}
