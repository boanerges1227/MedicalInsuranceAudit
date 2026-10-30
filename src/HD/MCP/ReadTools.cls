Class HD.MCP.ReadTools Extends %AI.ToolSet [ DependsOn = (HD.MCP.ReadPolicy, HD.MCP.ReadAudit) ]
{
XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="MedicalAuditReadOnly">
 <Policies><Authorization Class="HD.MCP.ReadPolicy"/><Audit Class="HD.MCP.ReadAudit"/></Policies>
 <Tool Name="review_case" Method="ReviewCase"><Description>Read one authorized synthetic audit case by case ID and expected version.</Description></Tool>
 <Tool Name="review_policy" Method="ReviewPolicy"><Description>Read national policy evidence for one authorized synthetic case and expected version.</Description></Tool>
</ToolSet>
}
/// Return limited fields for the requested case, excluding raw patient data and secrets.
ClassMethod ReviewCase(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    set c=##class(HD.MCP.Access).Check(caseId,expectedVersion)
    quit {"caseId":(caseId),"version":(c.version),"eventId":(c.eventId),"status":(c.status),"risks":(c.risks)}
}
/// Return national policy evidence already linked to the current case without arbitrary database access.
ClassMethod ReviewPolicy(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    set c=##class(HD.MCP.Access).Check(caseId,expectedVersion)
    quit {"caseId":(caseId),"version":(c.version),"retrieval":(c.%Get("policyRetrieval",{})),"evidence":(c.%Get("policyEvidence",[]))}
}
}
