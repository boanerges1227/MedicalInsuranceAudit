Class HD.PolicyEvidence Extends %RegisteredObject
{
/// Retrieve fictional excerpts with reproducible handcrafted demo vectors; never treat fixtures as insurance policies.
ClassMethod Retrieve(encounterId As %String, queryPath As %String = "") As %DynamicObject
{
    // Use the package install directory to locate the synthetic query vector.
    if queryPath="" { set queryPath=##class(HD.PackageSetup).Root()_"samples/demo-query.json" }
    set refs=[],items=[],id="",notice="仅为虚构演示依据，非真实医保政策；不能用于违规认定或临床决策。"
    for {
        set id=$order(^HDData("resource",encounterId,"MedicationRequest",id)) quit:id=""
        set med={}.%FromJSON(^HDData("resource",encounterId,"MedicationRequest",id))
        if med.%Get("status","")="active" { do refs.%Push({"resource":("MedicationRequest/"_id),"path":"status","value":"active"}) }
    }
    if refs.%Size()=0 { quit {"status":"NOT_APPLICABLE","notice":"没有有效药品医嘱，未启动演示检索。","fhirEvidence":(refs),"items":(items)} }
    try {
        set f=##class(%Stream.FileCharacter).%New(),f.TranslateTable="UTF8",sc=f.LinkToFile(queryPath)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("QUERY_VECTOR_UNAVAILABLE") }
        set query={}.%FromJSON(f.Read()),hash=query.%Get("model_sha256",""),csv=query.%Get("vector_csv",""),prefix="synthetic-demo/"
        if (hash'="synthetic-vector-fixture-v1")!(query.%Get("source_scope","")'="synthetic-demo") { throw ##class(%Exception.General).%New("QUERY_MODEL_UNKNOWN") }
        // Validate only the synthetic demo corpus; published policies may use a separate Chinese embedding model.
        set st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT COUNT(*) AS n, COUNT(DISTINCT ModelHash) AS models, MIN(ModelHash) AS model FROM HD.NationalVectors WHERE SourcePath LIKE ?")
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("POLICY_DATABASE_UNAVAILABLE") }
        set rs=st.%Execute(prefix_"%") if 'rs.%Next() { throw ##class(%Exception.General).%New("POLICY_DATABASE_UNAVAILABLE") }
        if (rs.%Get("n")=0)!(rs.%Get("models")'=1)!($zconvert(rs.%Get("model"),"L")'=$zconvert(hash,"L")) { throw ##class(%Exception.General).%New("POLICY_MODEL_MISMATCH") }
        // Filter by source and model before computing Top N; filtering after a global ranking can still hide synthetic evidence.
        set hits=##class(HD.NationalVector).SearchScoped(csv,hash,prefix,2)
        for i=0:1:hits.%Size()-1 {
            set hit=hits.%Get(i),meta=hit.metadata
            // Require both the database path and metadata to belong to the synthetic corpus so one mislabeled field cannot cross the boundary.
            if ($extract(hit.%Get("source_path",""),1,$length(prefix))'=prefix)!(meta.%Get("source_scope","")'="synthetic-demo")!($extract(meta.%Get("original_path",""),1,$length(prefix))'=prefix) { continue }
            do items.%Push({"sourceId":(meta.%Get("source_id","")),"policyId":"SYNTHETIC-DEMO","title":(meta.%Get("title","合成演示依据")),"chunkId":(hit.%Get("chunk_id")),"excerpt":(hit.text),"score":(hit.score),"sourceUrl":"","policyUrl":"","sourcePath":(meta.%Get("original_path","")),"sourceSha256":(meta.%Get("original_sha256","")),"dates":(meta.%Get("dates",{})),"reviewFlags":(meta.%Get("review_flags",[])),"reviewRequired":true,"synthetic":true})
        }
        set state=$select(items.%Size()>0:"FOUND",1:"NO_MATCH")
    } catch ex { set state="UNAVAILABLE",notice=notice_"演示向量检索当前不可用。" }
    quit {"status":(state),"notice":(notice),"fhirEvidence":(refs),"items":(items)}
}
}
