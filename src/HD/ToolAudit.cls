Class HD.ToolAudit Extends %AI.Policy.Audit
{
/// Record actual tool identity, duration, and outcome; never inspect arguments, evidence, or returned text.
Method %LogExecution(call As %DynamicObject, metadata As %DynamicObject, result As %DynamicObject, duration As %Integer, status As %Status) As %Status
{
    if '$isobject($get(%HDTraceContext)) { quit 1 }
    set scope=%HDTraceContext
    set name=call.%Get("name","")
    if $isobject(result) { set name=result.%Get("tool_name",name) }
    if (name'="get_case_evidence")&&(name'="get_policy_evidence") { set name="unregistered" }
    try { do scope.Tool(name,duration,$system.Status.IsOK(status)) } catch ex { set scope.Failed=1 return $system.Status.Error(5001,"TRACE_FAILED") }
    quit 1
}

/// Record authorization denials without pretending the tool executed or manufacturing a duration.
Method %LogDenial(call As %DynamicObject, metadata As %DynamicObject, status As %Status) As %Status
{
    if '$isobject($get(%HDTraceContext)) { quit 1 }
    set scope=%HDTraceContext
    set name=call.%Get("name","")
    if (name'="get_case_evidence")&&(name'="get_policy_evidence") { set name="unregistered" }
    try { do scope.Tool(name,0,0,1) } catch ex { set scope.Failed=1 return $system.Status.Error(5001,"TRACE_FAILED") }
    quit 1
}
}
