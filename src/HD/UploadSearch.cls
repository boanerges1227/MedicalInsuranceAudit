Class HD.UploadSearch Extends %RegisteredObject
{
/// Generate the query vector with the same model as the uploaded documents; retrieve only upload chunks with the same model fingerprint.
ClassMethod Search(body As %DynamicObject) As %DynamicObject
{
    set query=body.%Get("query","")
    if ($zstrip(query,"<>W")="")!($length(query)>300) { throw ##class(%Exception.General).%New("UPLOAD_QUERY_INVALID") }
    // Return an explicit error when the embedded method fails; never substitute a hand-made demo vector for the real query vector.
    try { set embedding={}.%FromJSON(##class(HD.EmbeddedVector).Encode(query,1)) }
    catch ex { throw ##class(%Exception.General).%New("EMBEDDING_UNAVAILABLE") }
    if (embedding.%Get("status","")'="OK")&&(embedding.%Get("code","")="INVALID_INPUT") { throw ##class(%Exception.General).%New("UPLOAD_QUERY_INVALID") }
    set model=embedding.%Get("model_hash",""),vector=embedding.%Get("vector_csv","")
    if (embedding.%Get("status","")'="OK")!(embedding.%Get("dimensions",0)'=512)!(model'="e256a606233996478f0eb6c99c9814e3797043d4a5563b4646b10929546196e5")!($length(vector,",")'=512) { throw ##class(%Exception.General).%New("EMBEDDING_UNAVAILABLE") }
    set items=[],st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT COUNT(*) AS total FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("UPLOAD_SEARCH_FAILED") }
    set rs=st.%Execute("HD","UploadedVectors")
    if 'rs.%Next() { throw ##class(%Exception.General).%New("UPLOAD_SEARCH_FAILED") }
    if rs.%Get("total")=0 { return {"status":"OK","items":(items)} }
    // Model-fingerprint filtering avoids comparing same-dimension vectors from different semantic spaces.
    set st=##class(%SQL.Statement).%New(),st.%SelectMode=1
    set sc=st.%Prepare("SELECT TOP 10 JobId,ChunkIndex,ChunkText,ModelHash,VECTOR_COSINE(Embedding,TO_VECTOR(?,FLOAT,512)) AS score FROM HD.UploadedVectors WHERE ModelHash = ? ORDER BY score DESC")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("UPLOAD_SEARCH_FAILED") }
    set rs=st.%Execute(vector,model)
    if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("UPLOAD_SEARCH_FAILED") }
    while rs.%Next() {
        set jobId=+rs.%Get("JobId"),filename=$get(^HDUpload("job",jobId,"filename"),""),excerpt=rs.%Get("ChunkText")
        do items.%Push({"jobId":(jobId),"filename":(filename),"chunkIndex":(+rs.%Get("ChunkIndex")),"excerpt":(excerpt),"score":(+rs.%Get("score")),"modelHash":(rs.%Get("ModelHash"))})
    }
    return {"status":"OK","items":(items)}
}
}
