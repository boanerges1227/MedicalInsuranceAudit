Class HD.FHIRRoute Extends Ens.BusinessOperation
{
/// Simulate clinical resource routing and persist FHIR resources for the encounter.
Method OnMessage(request As HD.Request, Output response As HD.Reply) As %Status
{
    set response=##class(HD.Reply).%New()
    try { set result=##class(HD.Store).Route({}.%FromJSON(request.Payload)) }
    catch ex { set result={"error":(ex.Name)} }
    set response.Payload=result.%ToJSON()
    quit 1
}
}
