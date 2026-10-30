Class HD.UploadVector Extends %RegisteredObject
{
/// Create a restricted upload task; persist raw chunks in IRIS and generate the task ID on the server.
ClassMethod Create(body As %DynamicObject) As %DynamicObject
{
    set name=body.%Get("filename"),size=+body.%Get("size"),parts=+body.%Get("parts")
    if (name="")!($length(name)>180)!(name["/")!(name["\")!(size<1)!(size>2097152)!(parts<1)!(parts>64) { throw ##class(%Exception.General).%New("INVALID_UPLOAD") }
    set ext=$zconvert($piece(name,".",$length(name,".")),"L")
    if '$listfind($listfromstring("txt,md,docx"),ext) { throw ##class(%Exception.General).%New("UNSUPPORTED_FILE_TYPE") }
    set id=$increment(^HDUpload("counter"))
    set ^HDUpload("job",id,"filename")=name,^HDUpload("job",id,"size")=size,^HDUpload("job",id,"parts")=parts,^HDUpload("job",id,"received")=0,^HDUpload("job",id,"state")="UPLOADING",^HDUpload("job",id,"created")=$horolog
    return {"id":(id),"state":"UPLOADING"}
}

/// Receive Base64 chunks in order and reject invalid characters or unexpected sequence numbers.
ClassMethod Append(id As %String, body As %DynamicObject) As %DynamicObject
{
    if id'?1.N { throw ##class(%Exception.General).%New("INVALID_UPLOAD") }
    lock +^HDUpload("job",id):5 if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set index=+body.%Get("index"),chunk=body.%Get("data"),received=+$get(^HDUpload("job",id,"received"))
        if ($get(^HDUpload("job",id,"state"))'="UPLOADING")!(index'=received)!(index'<+$get(^HDUpload("job",id,"parts")))!($length(chunk)<1)!($length(chunk)>60000)!($translate(chunk,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=","")'="") { throw ##class(%Exception.General).%New("INVALID_UPLOAD_CHUNK") }
        set ^HDUpload("job",id,"data",index)=chunk,^HDUpload("job",id,"received")=received+1
    } catch ex { lock -^HDUpload("job",id) throw ex }
    lock -^HDUpload("job",id)
    return {"received":(received+1)}
}

/// Queue the task only after every chunk has arrived.
ClassMethod Submit(id As %String) As %DynamicObject
{
    if id'?1.N { throw ##class(%Exception.General).%New("INVALID_UPLOAD") }
    lock +^HDUpload("job",id):5 if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        if ($get(^HDUpload("job",id,"state"))'="UPLOADING")!(+$get(^HDUpload("job",id,"received"))'=+$get(^HDUpload("job",id,"parts"))) { throw ##class(%Exception.General).%New("INCOMPLETE_UPLOAD") }
        set ^HDUpload("job",id,"state")="QUEUED",^HDUpload("queue",id)=""
    } catch ex { lock -^HDUpload("job",id) throw ex }
    lock -^HDUpload("job",id)
    return {"id":(+id),"state":"QUEUED"}
}

/// Return recent task status without file contents or chunks.
ClassMethod List() As %DynamicObject
{
    set out=[],id="",count=0
    for  { set id=$order(^HDUpload("job",id),-1) quit:id=""  quit:count=100  set count=count+1 do out.%Push({"id":(+id),"filename":($get(^HDUpload("job",id,"filename"))),"state":($get(^HDUpload("job",id,"state"))),"chunks":(+$get(^HDUpload("job",id,"chunks"))),"error":($get(^HDUpload("job",id,"error"))),"created":($get(^HDUpload("job",id,"created"))),"publication":(##class(HD.KnowledgePublish).Summary(id))}) }
    return {"jobs":(out),"workerHeartbeat":($get(^HDUpload("heartbeat")))}
}

/// Claim a task and update the local worker heartbeat; read chunks only through the local Docker session.
ClassMethod Claim()
{
    lock +^HDUpload("claim"):5 if '$test { quit }
    set ^HDUpload("heartbeat")=$horolog,id=$order(^HDUpload("queue",""))
    if id'="" {
        kill ^HDUpload("queue",id) set ^HDUpload("job",id,"state")="RUNNING"
        set meta={"id":(+id),"filename":(^HDUpload("job",id,"filename")),"size":(+^HDUpload("job",id,"size"))}
        write "UPLOAD_META=",meta.%ToJSON(),!
        for i=0:1:(^HDUpload("job",id,"parts")-1) { write "UPLOAD_PART=",^HDUpload("job",id,"data",i),! }
    }
    lock -^HDUpload("claim")
}

/// Recover interrupted tasks on worker restart; use a local file lock to enforce a single worker.
ClassMethod Recover()
{
    set id=""
    for  { set id=$order(^HDUpload("job",id)) quit:id=""  if $get(^HDUpload("job",id,"state"))="RUNNING" { set ^HDUpload("job",id,"state")="QUEUED",^HDUpload("queue",id)="" } }
}

/// Mark processing failure without deleting the source file so it remains available for investigation.
ClassMethod Fail(id As %Integer, code As %String)
{
    if $get(^HDUpload("job",id,"state"))="RUNNING" { set ^HDUpload("job",id,"state")="FAILED",^HDUpload("job",id,"error")=code }
}

/// Create a vector table separate from national policies, preserving the task, text, hashes, and model version per chunk.
ClassMethod Install()
{
    set st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT COUNT(*) AS total FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SCHEMA_CHECK_FAILED") }
    set rs=st.%Execute("HD","UploadedVectors")
    if 'rs.%Next() { throw ##class(%Exception.General).%New("SCHEMA_CHECK_FAILED") }
    if rs.%Get("total")=0 {
        set sql="CREATE TABLE HD.UploadedVectors (JobId INTEGER NOT NULL, ChunkIndex INTEGER NOT NULL, TextHash VARCHAR(64) NOT NULL, ModelHash VARCHAR(64) NOT NULL, ChunkText VARCHAR(4000), Embedding VECTOR(FLOAT,512), PRIMARY KEY (JobId,ChunkIndex))"
        set rs=##class(%SQL.Statement).%ExecDirect(,sql)
        if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("CREATE_TABLE_FAILED") }
    }
}

/// Import all chunks in one transaction and roll back failures so completed tasks cannot lack vectors.
ClassMethod Import(id As %Integer, containerMode As %Boolean = 0)
{
    if $get(^HDUpload("job",id,"state"))'="RUNNING" { throw ##class(%Exception.General).%New("INVALID_UPLOAD_STATE") }
    do ..Install()
    set dir=$select(containerMode:"/durable/iris/private/upload-private/",1:"/workspace/src/upload-private/")
    set stream=##class(%Stream.FileCharacter).%New(),stream.TranslateTable="UTF8",sc=stream.LinkToFile(dir_id_".jsonl")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("UPLOAD_INPUT_UNAVAILABLE") }
    set put=##class(%SQL.Statement).%New(),put.%SelectMode=1,sc=put.%Prepare("INSERT INTO HD.UploadedVectors (JobId,ChunkIndex,TextHash,ModelHash,ChunkText,Embedding) VALUES (?,?,?,?,?,TO_VECTOR(?,FLOAT,512))")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("INSERT_PREPARE_FAILED") }
    tstart
    try {
        set count=0
        while 'stream.AtEnd {
            set line=stream.ReadLine() if line="" { continue }
            set row={}.%FromJSON(line),vec=row.%Get("vector_csv")
            if ($length(vec,",")'=512)!(+row.%Get("index")'=count) { throw ##class(%Exception.General).%New("INVALID_VECTOR") }
            set rs=put.%Execute(id,count,row.%Get("text_sha256"),row.%Get("model_sha256"),row.%Get("text"),vec)
            if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("INSERT_FAILED") }
            set count=count+1
        }
        if count=0 { throw ##class(%Exception.General).%New("EMPTY_DOCUMENT") }
        set ^HDUpload("job",id,"chunks")=count,^HDUpload("job",id,"state")="SUCCEEDED"
        tcommit
    } catch ex {
        trollback
        throw ex
    }
    write "UPLOAD_IMPORTED=",count,!
}
}
