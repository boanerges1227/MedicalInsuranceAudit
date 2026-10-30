Class HD.MCP.ReadPolicy Extends %AI.Policy.Authorization
{
/// List only explicitly allowed read-only tools for authenticated callers.
Method %CanList(toolref As %String, metadata As %DynamicObject) As %Boolean
{
    set actor=$get(^||HDMCP("actor")),hash=$get(^||HDMCP("hash"))
    try { if ##class(HD.MCP.Access).Validate(hash)'=actor { return 0 } } catch ex { return 0 }
    quit ($listfind($listfromstring("review_case,review_policy"),metadata.%Get("name",""))>0)
}
/// Revalidate the tool source, case permissions, and version before execution.
Method %CanExecute(toolref As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
    try {
        if '$listfind($listfromstring("review_case,review_policy"),call.%Get("name","")) { throw ##class(%Exception.General).%New("MCP_TOOL_DENIED") }
        if metadata.%Get("origin_class","")'="HD.MCP.ReadTools" { throw ##class(%Exception.General).%New("MCP_TOOL_DENIED") }
        set args=call.%Get("arguments",{})
        if '$isobject(args) { set args={}.%FromJSON(args) }
        set c=##class(HD.MCP.Access).Check(args.%Get("caseId",""),+args.%Get("expectedVersion",0))
        return 1
    } catch ex {
        set safe=##class(HD.MCP.ReadAudit).Arguments(call)
        do ##class(HD.MCP.ReadAudit).Record(call.%Get("name",""),"DENIED",0,safe.%Get("caseId",""),+safe.%Get("expectedVersion",0))
        return $system.Status.Error(5001,"MCP_READ_DENIED")
    }
}
}
