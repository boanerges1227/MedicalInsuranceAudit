Class HD.AgentAuthorization Extends %AI.Policy.Authorization
{
/// Allow only registered project tools with read-only access and check case context before each execution.
Method %CanExecute(toolref As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
    try {
        set name=call.%Get("name","")
        if metadata.%Get("origin_class","")'="HD.AgentTools" { throw ##class(%Exception.General).%New("TOOL_DENIED") }
        if (toolref'=name)&&(toolref'="iris:HD.AgentTools") { throw ##class(%Exception.General).%New("TOOL_DENIED") }
        if (name'="get_case_evidence")&&(name'="get_policy_evidence") { throw ##class(%Exception.General).%New("TOOL_DENIED") }
        set c=##class(HD.AgentTools).Context()
        return 1
    } catch ex { return $system.Status.Error(5001,"TOOL_AUTHORIZATION_DENIED") }
}
}
