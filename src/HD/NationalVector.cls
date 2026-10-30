Class HD.NationalVector Extends %RegisteredObject
{
/// Test the database cosine function instead of inferring vector support from the version number.
ClassMethod SelfTest()
{
    set st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT VECTOR_COSINE(TO_VECTOR('1,0',FLOAT),TO_VECTOR('1,0',FLOAT)) AS score")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("VECTOR_PREPARE_FAILED") }
    set rs=st.%Execute()
    if 'rs.%Next() { throw ##class(%Exception.General).%New("VECTOR_QUERY_FAILED") }
    if rs.%Get("score")'=1 { throw ##class(%Exception.General).%New("VECTOR_VALUE_FAILED") }
    write "NATIONAL_VECTOR_SELFTEST_OK",!
}

/// Create a separate national policy vector table with source metadata and a fixed model dimension.
ClassMethod Install()
{
    set st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT COUNT(*) AS total FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SCHEMA_CHECK_FAILED") }
    set rs=st.%Execute("HD","NationalVectors")
    if 'rs.%Next() { throw ##class(%Exception.General).%New("SCHEMA_CHECK_FAILED") }
    if rs.%Get("total")=0 {
        set sql="CREATE TABLE HD.NationalVectors (ChunkId VARCHAR(512) NOT NULL, TextHash VARCHAR(64) NOT NULL, ModelHash VARCHAR(64) NOT NULL, SourcePath VARCHAR(512) NOT NULL, ChunkText VARCHAR(4000), Metadata VARCHAR(16000), Embedding VECTOR(FLOAT,512), PRIMARY KEY (ChunkId))"
        set rs=##class(%SQL.Statement).%ExecDirect(,sql)
        if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("CREATE_TABLE_FAILED: "_rs.%Message) }
    }
    write "NATIONAL_VECTOR_SCHEMA_READY",!
}

/// Validate source scope, vector length, and model hash; skip existing IDs only when their content is identical.
ClassMethod Import(path As %String)
{
    lock +^HDNationalVectorImport($namespace):10
    if '$test { throw ##class(%Exception.General).%New("IMPORT_BUSY") }
    try {
        set stream=##class(%Stream.FileCharacter).%New(),stream.TranslateTable="UTF8",sc=stream.LinkToFile(path)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("INPUT_FILE_UNAVAILABLE") }
        set get=##class(%SQL.Statement).%New(),sc=get.%Prepare("SELECT TextHash,ModelHash,SourcePath,Metadata FROM HD.NationalVectors WHERE ChunkId = ?")
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("QUERY_PREPARE_FAILED") }
        set put=##class(%SQL.Statement).%New(),put.%SelectMode=1,sc=put.%Prepare("INSERT INTO HD.NationalVectors (ChunkId,TextHash,ModelHash,SourcePath,ChunkText,Metadata,Embedding) VALUES (?,?,?,?,?,?,TO_VECTOR(?,FLOAT,512))")
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("INSERT_PREPARE_FAILED: "_$system.Status.GetErrorText(sc)) }
        set added=0,skipped=0
        while 'stream.AtEnd {
            set text=stream.ReadLine() if text="" { continue }
            set row={}.%FromJSON(text),source=row.%Get("original_path")
            // Allow only explicitly synthetic demo sources; real policies require separate authorization and an import workflow.
            if ($extract(source,1,$length("synthetic-demo/"))'="synthetic-demo/")!(source["..")!(row.%Get("source_scope","")'="synthetic-demo") { throw ##class(%Exception.General).%New("SOURCE_OUTSIDE_DEMO_SCOPE") }
            if $length(row.%Get("vector_csv"),",")'=512 { throw ##class(%Exception.General).%New("BAD_VECTOR_DIMENSION") }
            set vec=row.%Get("vector_csv") do row.%Remove("vector_csv")
            set rs=get.%Execute(row.%Get("chunk_id"))
            if rs.%Next() {
                if (rs.%Get("TextHash")'=row.%Get("text_sha256"))!(rs.%Get("ModelHash")'=row.%Get("model_sha256"))!(rs.%Get("SourcePath")'=source)!(rs.%Get("Metadata")'=row.%ToJSON()) { throw ##class(%Exception.General).%New("CHUNK_VERSION_CONFLICT") }
                set skipped=skipped+1 continue
            }
            set rs=put.%Execute(row.%Get("chunk_id"),row.%Get("text_sha256"),row.%Get("model_sha256"),source,row.text,row.%ToJSON(),vec)
            if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("INSERT_FAILED: "_rs.%Message) }
            set added=added+1
            if (added#500)=0 { write "IMPORT_PROGRESS=",added,! }
        }
        write "NATIONAL_IMPORT_ADDED=",added," SKIPPED=",skipped,!
    } catch ex { lock -^HDNationalVectorImport($namespace) throw ex }
    lock -^HDNationalVectorImport($namespace)
}

/// Compute cosine similarity in IRIS using a query vector from the same model and return source metadata.
ClassMethod Search(csv As %String, top As %Integer = 10) As %DynamicArray
{
    if ($length(csv,",")'=512)!(top<1)!(top>50) { throw ##class(%Exception.General).%New("INVALID_SEARCH_INPUT") }
    set st=##class(%SQL.Statement).%New(),st.%SelectMode=1,sql="SELECT TOP "_top_" ChunkId,ChunkText,Metadata,VECTOR_COSINE(Embedding,TO_VECTOR(?,FLOAT,512)) AS score FROM HD.NationalVectors ORDER BY score DESC"
    set sc=st.%Prepare(sql) if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SEARCH_PREPARE_FAILED") }
    set rs=st.%Execute(csv),out=[]
    while rs.%Next() { do out.%Push({"chunk_id":(rs.%Get("ChunkId")),"text":(rs.%Get("ChunkText")),"score":(rs.%Get("score")),"metadata":({}.%FromJSON(rs.%Get("Metadata")))}) }
    if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("SEARCH_FAILED") }
    return out
}
/// Verify in the database that every record belongs to the synthetic demo scope.
ClassMethod VerifyScope()
{
    set st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT SourcePath FROM HD.NationalVectors"),rs=st.%Execute(),count=0,bad=0,prefix="synthetic-demo/"
    while rs.%Next() { set p=rs.%Get("SourcePath"),count=count+1 if ($extract(p,1,$length(prefix))'=prefix)!(p["..") { set bad=bad+1 } }
    write "SCOPE_TOTAL=",count," OUT_OF_SCOPE=",bad,!
}

}
