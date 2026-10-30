Class HD.MCP.Status Extends %RegisteredObject
{
/// Probe the local gateway HTTP response; reachability does not prove tool authorization or end-to-end success.
ClassMethod GatewayProbe() As %String
{
    try {
        set req=##class(%Net.HttpRequest).%New(),req.Server="mcp-gateway",req.Port=52875,req.Timeout=2
        set sc=req.Get("/mcp")
        if $system.Status.IsOK(sc),+req.HttpResponse.StatusCode>0 { return "REACHABLE" }
    } catch ex { set ignored=1 }
    quit "UNREACHABLE"
}
/// Store the service switch in IRIS, default it to enabled, and read it during every authentication and tool check.
ClassMethod Enabled() As %Boolean { quit '$get(^HDMCPAccess($namespace,"serviceDisabled")) }
/// Summarize audit history and return the current gateway probe and service switch separately.
ClassMethod Snapshot() As %DynamicObject
{
    set n=0,ok=0,failed=0,last=0,id=""
    for {
        set id=$order(^HDMCPAccess($namespace,"audit",id)) quit:id=""
        try { set a={}.%FromJSON(^HDMCPAccess($namespace,"audit",id)) } catch ex { continue }
        set n=n+1
        if a.%Get("outcome","")="ALLOWED" { set ok=ok+1 } else { set failed=failed+1 }
        if a.%Get("occurredAtEpoch",0)>last { set last=a.occurredAtEpoch }
    }
    quit {"endpoint":"http://127.0.0.1:52875/mcp","tools":["review_case","review_policy"],"observedCalls":(n),"observedSucceeded":(ok),"observedFailed":(failed),"lastObservedEpoch":(last),"serviceEnabled":(..Enabled()),"gatewayReachability":(..GatewayProbe())}
}
/// Change the switch under the authentication lock; running requests may finish while new calls are rejected immediately.
ClassMethod SetEnabled(data As %DynamicObject) As %DynamicObject
{
    do ##class(HD.AdminSession).Require()
    if data.%GetTypeOf("enabled")'="boolean" { throw ##class(%Exception.General).%New("INVALID_MCP_SERVICE_STATE") }
    lock +^HDMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    set ^HDMCPAccess($namespace,"serviceDisabled")='data.enabled
    lock -^HDMCPAccess($namespace,"lock")
    quit {"serviceEnabled":(..Enabled())}
}
/// Page backward through recent audit records; return call metadata without tokens or complete requests.
ClassMethod Logs(before As %String = "", limit As %Integer = 10) As %DynamicObject
{
    if (before'="")&&('$match(before,"^[1-9][0-9]{0,17}$")) { throw ##class(%Exception.General).%New("INVALID_MCP_LOG_CURSOR") }
    if (limit<1)!(limit>50) { set limit=10 }
    set rows=[],id=$select(before="":"",1:before),next="",more=0
    for i=1:1:limit {
        set id=$order(^HDMCPAccess($namespace,"audit",id),-1) quit:id=""
        try { set item={}.%FromJSON(^HDMCPAccess($namespace,"audit",id)) } catch ex { continue }
        set item.id=id do rows.%Push(item) set next=id
    }
    if next'="" { set more=($order(^HDMCPAccess($namespace,"audit",next),-1)'="") }
    quit {"items":(rows),"nextBefore":($select(more:next,1:"")),"hasMore":(more)}
}
}
