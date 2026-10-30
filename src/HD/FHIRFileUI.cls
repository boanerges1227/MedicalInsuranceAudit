Include %occStatus
Class HD.FHIRFileUI Extends %RegisteredObject
{
/// Write the page-supplied synthetic file to a dedicated inbox and hand it to the Adapter via atomic rename.
ClassMethod Submit(data As %DynamicObject) As %DynamicObject
{
    set content=data.%Get("content",""),name=$extract(data.%Get("name","test.json"),1,128)
    if (content="")!($length($zcvt(content,"O","UTF8"))>1048576) { throw ##class(%Exception.General).%New("FILE_SIZE_INVALID") }
    // Match the Adapter directory currently configured in the Production to avoid uploading to an unmonitored location.
    set dir=##class(Ens.Director).GetAdapterSettingValue("FHIRFileIntake","Inbox",.configStatus)
    if $system.Status.IsError(configStatus)!(dir="") { throw ##class(%Exception.General).%New("FHIR_INBOX_UNAVAILABLE") }
    if $extract(dir,*)'="/" { set dir=dir_"/" }
    if '##class(%File).DirectoryExists(dir) { throw ##class(%Exception.General).%New("FHIR_INBOX_UNAVAILABLE") }
    set id=$system.Encryption.Base32HexEncode($system.Encryption.GenCryptRand(16,1),1),file="ui-"_id_".ready.json",tmp=dir_"ui-"_id_".tmp",eventId=""
    // The event id only links to the actual event; on parse failure the Adapter still receives it and records the failure.
    try { set bundle={}.%FromJSON(content),eventId=$extract(bundle.%Get("id",""),1,64) } catch ex { set eventId="" }
    set record={"id":(id),"name":(name),"status":"QUEUED","eventId":(eventId),"createdAt":($ztimestamp),"updatedAt":($ztimestamp),"history":[]}
    set stream=##class(%Stream.FileCharacter).%New(),stream.TranslateTable="UTF8",sc=stream.LinkToFile(tmp)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("FHIR_FILE_WRITE_FAILED") }
    set sc=stream.Write(content) if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("FHIR_FILE_WRITE_FAILED") }
    set sc=stream.%Save() if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("FHIR_FILE_WRITE_FAILED") }
    set ^HDFHIRFile("ui",id)=record.%ToJSON(),^HDFHIRFile("uiByName",file)=id,seq=$increment(^HDFHIRFile("uiSequence")),^HDFHIRFile("uiOrder",seq)=id
    if '##class(%File).Rename(tmp,dir_file) { kill ^HDFHIRFile("ui",id),^HDFHIRFile("uiByName",file),^HDFHIRFile("uiOrder",seq) throw ##class(%Exception.General).%New("FHIR_FILE_RENAME_FAILED") }
    quit record
}

/// Update only file records submitted from the page; externally delivered files keep their original handling.
ClassMethod Update(name As %String, status As %String)
{
    set id=$get(^HDFHIRFile("uiByName",name))
    if id="" { quit }
    if '$data(^HDFHIRFile("ui",id)) { quit }
    set row={}.%FromJSON(^HDFHIRFile("ui",id))
    // When the same file is rescanned, keep the first success and do not mislabel it as a duplicate upload.
    if row.status=status { quit }
    if (row.status="PROCESSED")&&(status="DUPLICATE") { quit }
    set now=$ztimestamp,history=row.%Get("history",[])
    if history.%Size()'<30 { do history.%Remove(0) }
    do history.%Push({"status":(status),"at":(now)})
    set row.history=history,row.status=status,row.updatedAt=now,^HDFHIRFile("ui",id)=row.%ToJSON()
}

/// Return recent file status and attach the real audit event only after the Adapter has processed it.
ClassMethod List() As %DynamicObject
{
    set out=[],seq="",events=##class(HD.EventMonitor).List().events
    for {
        set seq=$order(^HDFHIRFile("uiOrder",seq),-1) quit:seq=""
        set id=^HDFHIRFile("uiOrder",seq)
        if '$data(^HDFHIRFile("ui",id)) { continue }
        set row={}.%FromJSON(^HDFHIRFile("ui",id))
        if ((row.status="PROCESSED")!(row.status="DUPLICATE"))&&(row.eventId'="") {
            for i=0:1:events.%Size()-1 { set event=events.%Get(i) if event.eventId=row.eventId { set row.event=event quit } }
        }
        do out.%Push(row)
        if out.%Size()'<100 { quit }
    }
    quit {"files":(out)}
}
}
