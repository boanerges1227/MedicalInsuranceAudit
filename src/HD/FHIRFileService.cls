Include %occStatus

Class HD.FHIRFileService Extends HD.Service
{
Parameter ADAPTER = "HD.FHIRFileAdapter";

/// Parse file content into a FHIR Bundle, reusing the existing business flow and idempotency checks.
Method OnProcessInput(input As %RegisteredObject, Output output As %RegisteredObject) As %Status
{
    set sc=1
    // Record the node only after the business service actually receives the file; never infer calls that did not happen.
    if $isobject(input),input.%IsA("HD.Request") { do ##class(HD.FHIRFileUI).Update(input.FileName,"SERVICE_RECEIVED") }
    try {
        set bundle={}.%FromJSON(input.Payload),result={}
        set sc=..Submit(bundle,.result)
        if $system.Status.IsOK(sc),result.%IsDefined("error") { set sc=$$$ERROR($$$GeneralError,"FHIR_FILE_REJECTED") }
        if $system.Status.IsOK(sc) { set output=##class(HD.Reply).%New(),output.Payload=result.%ToJSON() }
    } catch ex { set sc=$$$ERROR($$$GeneralError,"FHIR_FILE_REJECTED") }
    quit sc
}
}
