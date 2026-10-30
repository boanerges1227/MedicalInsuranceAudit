Include %occStatus

Class HD.FHIRFileAdapter Extends Ens.InboundAdapter
{
Parameter SETTINGS = "Inbox:Basic";
Property Inbox As %String [ InitialExpression = "/durable/iris/private/fhir-inbox/" ];

/// Periodically scan fully-delivered JSON files and hand them to the business service; original files are always kept.
Method OnTask() As %Status
{
    if '##class(%File).DirectoryExists(..Inbox) { quit 1 }
    set statement=##class(%SQL.Statement).%New(),sc=statement.%PrepareClassQuery("%File","FileSet")
    if $system.Status.IsError(sc) { quit sc }
    set files=statement.%Execute(..Inbox,"*.ready.json","Name")
    if files.%SQLCODE<0 { quit $$$ERROR($$$GeneralError,"FHIR_FILE_LIST_FAILED") }
    while files.%Next() {
        if files.%Get("Type")'="F" { continue }
        set path=files.%Get("Name"),name=files.%Get("ItemName"),size=+files.%Get("Size")
        if (size<1)!(size>1048576) { set ^HDFHIRFile("invalid",name)="SIZE_INVALID" continue }
        set stream=##class(%Stream.FileCharacter).%New(),stream.TranslateTable="UTF8",sc=stream.LinkToFile(path)
        if $system.Status.IsError(sc) { continue }
        set content=stream.Read(1048577)
        if stream.AtEnd'=1 { set ^HDFHIRFile("invalid",name)="SIZE_INVALID" continue }
        // Deduplicate by SHA-256 of the full content; replayed files still keep the original for inspection.
        set hash=$system.Encryption.Base64Encode($system.Encryption.SHAHash(256,content))
        if $data(^HDFHIRFile("processed",hash)) { do ##class(HD.FHIRFileUI).Update(name,"DUPLICATE") continue }
        set now=$piece($horolog,1)*86400+$piece($horolog,2),last=+$get(^HDFHIRFile("attempt",hash))
        if (last>0)&&(now-last<30) { continue }
        set ^HDFHIRFile("attempt",hash)=now,request=##class(HD.Request).%New(),request.Payload=content,request.FileName=name
        do ##class(HD.FHIRFileUI).Update(name,"PROCESSING")
        set sc=..BusinessHost.ProcessInput(request)
        if $system.Status.IsOK(sc) { set ^HDFHIRFile("processed",hash)=$ztimestamp kill ^HDFHIRFile("invalid",name) do ##class(HD.FHIRFileUI).Update(name,"PROCESSED") }
        else { set ^HDFHIRFile("invalid",name)="PROCESSING_FAILED" do ##class(HD.FHIRFileUI).Update(name,"FAILED") }
        quit
    }
    quit 1
}
}
