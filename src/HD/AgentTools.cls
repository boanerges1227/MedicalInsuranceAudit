Class HD.AgentTools Extends %AI.ToolSet
{
XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="InsuranceEvidence">
 <Tool Name="get_case_evidence" Method="Summary"><Description>Read the current event's synthetic audit findings and evidence references.</Description></Tool>
 <Tool Name="get_policy_evidence" Method="Policy"><Description>Read synthetic demonstration evidence excerpts and their source metadata.</Description></Tool>
</ToolSet>
}

/// Bind tool calls to the server-selected encounter, event, and version; the model cannot select another case.
ClassMethod Begin(encounterId As %String, eventId As %String, version As %Integer, runId As %Integer = 0)
{
    set c=##class(HD.Store).Detail(encounterId)
    if (c.eventId'=eventId)!(c.version'=version) { throw ##class(%Exception.General).%New("STALE_CASE") }
    if (c.status="PROCESSING")!(c.status="AUDIT_FAILED") { throw ##class(%Exception.General).%New("CASE_NOT_READY") }
    kill ^HDData("agentContext",$job)
    set ^HDData("agentContext",$job,"encounter")=encounterId,^HDData("agentContext",$job,"event")=eventId,^HDData("agentContext",$job,"version")=version,^HDData("agentContext",$job,"calls")=0,^HDData("agentContext",$job,"runId")=runId
}

/// Check the version and call limit every time; omit case ID parameters to prevent unauthorized selection.
ClassMethod Context() As %DynamicObject
{
    set id=$get(^HDData("agentContext",$job,"encounter"))
    if id="" { throw ##class(%Exception.General).%New("NO_CASE_CONTEXT") }
    set c=##class(HD.Store).Detail(id)
    if (c.eventId'=$get(^HDData("agentContext",$job,"event")))!(c.version'=$get(^HDData("agentContext",$job,"version"))) { throw ##class(%Exception.General).%New("STALE_CASE") }
    if $increment(^HDData("agentContext",$job,"calls"))>8 { throw ##class(%Exception.General).%New("TOOL_LIMIT") }
    quit c
}

/// Clear temporary process context so reused workers cannot inherit another case.
ClassMethod End()
{
    kill ^HDData("agentContext",$job)
}

/// Return this event's demo findings and evidence paths without sending patient names or raw FHIR bundles to the model.
ClassMethod Summary() As %DynamicObject
{
    set c=..Context(),risks=[]
    for i=0:1:c.risks.%Size()-1 { set r=c.risks.%Get(i) do risks.%Push({"id":(r.id),"title":(r.title),"evidence":(r.evidence),"pending":(r.pending)}) }
    set id="case-"_c.version,^HDData("agentContext",$job,"evidence",id)="case"
    set result={"evidenceId":(id),"caseVersion":(c.version),"findings":(risks),"scope":"synthetic-demo","notice":"仅供人工核查，不认定违规；数据不足时明确指出。"}
    do ##class(HD.AgentRequest).TraceSafe(+$get(^HDData("agentContext",$job,"runId")),"CASE_EVIDENCE")
    quit result
}

/// Return only fictional excerpts and source metadata already linked to the current case; accept no arbitrary search or write parameters.
ClassMethod Policy() As %DynamicObject
{
    set c=..Context(),id="policy-"_c.version,^HDData("agentContext",$job,"evidence",id)="policy"
    set result={"evidenceId":(id),"status":(c.policyRetrieval.%Get("status","UNAVAILABLE")),"items":(c.%Get("policyEvidence",[])),"notice":"政策适用性、生效时间及例外需人工核实。"}
    do ##class(HD.AgentRequest).TraceSafe(+$get(^HDData("agentContext",$job,"runId")),"POLICY_EVIDENCE")
    quit result
}
}
