Class HD.Governance Extends %RegisteredObject
{
/// Search synthetic samples and published knowledge evidence by keyword; exclude staged uploads and withdrawn content.
ClassMethod Policies(query As %String = "") As %DynamicObject
{
    set items=[],seen={},counted={},syntheticPrefix="synthetic-demo/",publishedPrefix="published-upload/",query=$zstrip(query,"<>W"),sourceCount=0
    // Generate SQL at class compilation so the web identity can read data without dynamic query plan generation permissions.
    &sql(DECLARE policyCursor CURSOR FOR SELECT SourcePath,ChunkText,Metadata FROM HD.NationalVectors ORDER BY SourcePath,ChunkId)
    &sql(OPEN policyCursor)
    if SQLCODE<0 { throw ##class(%Exception.General).%New("POLICY_DATABASE_UNAVAILABLE") }
    for {
        &sql(FETCH policyCursor INTO :path,:text,:metadata)
        if SQLCODE'=0 { quit }
        // Validate the stored path, metadata path, and publication state together so staged or withdrawn uploads cannot enter the knowledge library.
        if path[".." { continue }
        set meta={}.%FromJSON(metadata)
        if meta.%Get("original_path","")'=path { continue }
        set synthetic=$extract(path,1,$length(syntheticPrefix))=syntheticPrefix,published=$extract(path,1,$length(publishedPrefix))=publishedPrefix
        if 'synthetic,'published { continue }
        if published {
            set sourceJobId=+meta.%Get("sourceJobId",0)
            if (sourceJobId<1)!(meta.%Get("publicationStatus","")'="PUBLISHED")!($get(^HDUpload("publish",sourceJobId,"state"))'="PUBLISHED")!($get(^HDUpload("publish",sourceJobId,"sourcePath"))'=path) { continue }
        } else { set sourceJobId=0 }
        set sourceId=meta.%Get("source_id","")
        if sourceId="" { continue }
        // Count all compliant source documents in the knowledge base, independent of the keyword and display limit, for the page to show the data volume.
        if 'counted.%IsDefined(path) { do counted.%Set(path,1) set sourceCount=sourceCount+1 }
        // Show only the first keyword-matching chunk per source, up to 20; keep iterating past the cap to finish counting.
        if seen.%IsDefined(path) { continue }
        set title=meta.%Get("title","")
        if (query'="")&&(text'[query)&&(title'[query) { continue }
        if items.%Size()'<20 { continue }
        // Show context around body keyword matches so the displayed excerpt preserves the matching evidence.
        set pos=$find(text,query),start=1,length=500
        if (query'="")&&(pos>0) { set start=$select(pos-$length(query)-100>1:pos-$length(query)-100,1:1),length=$select($length(query)+100>500:$length(query)+100,1:500) }
        do seen.%Set(path,1)
        do items.%Push({"title":(title),"sourceId":(sourceId),"recordType":(meta.%Get("record_type","")),"parentPolicyIds":(meta.%Get("parent_policy_ids",[])),"sourceUrl":(meta.%Get("source_url","")),"excerpt":($extract(text,start,start+length-1)),"dates":(meta.%Get("dates",{})),"reviewFlags":(meta.%Get("review_flags",[])),"region":(meta.%Get("region","")),"synthetic":(synthetic),"publicationStatus":(meta.%Get("publicationStatus",$select(synthetic:"SYNTHETIC",1:""))),"publishedAt":(meta.%Get("publishedAt","")),"publishedBy":(meta.%Get("publishedBy","")),"needsReview":(meta.%Get("needsReview",1)),"sourceJobId":(sourceJobId)})
    }
    set fetchCode=SQLCODE
    &sql(CLOSE policyCursor)
    if fetchCode<0 { throw ##class(%Exception.General).%New("POLICY_DATABASE_UNAVAILABLE") }
    quit {"items":(items),"mode":"keyword","total":(sourceCount)}
}

/// Load national rule drafts read-only; validate their source and disabled state without enabling them.
ClassMethod Rules(path As %String = "") As %DynamicObject
{
    // The installed package and source deployment share the same resource-locating method.
    if path="" { set path=##class(HD.PackageSetup).Root()_"samples/demo-rules.json" }
    if '##class(%File).Exists(path) { throw ##class(%Exception.General).%New("RULES_FILE_UNAVAILABLE") }
    set f=##class(%Stream.FileCharacter).%New(),f.TranslateTable="UTF8",sc=f.LinkToFile(path)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("RULES_FILE_UNAVAILABLE") }
    try { set data={}.%FromJSON(f.Read()) } catch ex { throw ##class(%Exception.General).%New("RULES_FILE_INVALID") }
    set rules=data.%Get("rules","")
    if '$isobject(rules) { throw ##class(%Exception.General).%New("RULES_FILE_INVALID") }
    for i=0:1:rules.%Size()-1 {
        set rule=rules.%Get(i),region=rule.%Get("region",{}),source=rule.%Get("source",{}),deployment=rule.%Get("deployment",{})
        // Accept only explicitly fictional release fixtures; never present them as effective policies.
        set province=region.%Get("province",""),path=source.%Get("local_original_path",""),prefix="synthetic-demo/"
        if (province'="演示样本")!('rule.%Get("sample",0))!($extract(path,1,$length(prefix))'=prefix)!(path["..") { throw ##class(%Exception.General).%New("RULES_SCOPE_INVALID") }
        if 'deployment.%IsDefined("enabled") { throw ##class(%Exception.General).%New("RULES_ENABLED_INVALID") }
        if deployment.%Get("enabled") { throw ##class(%Exception.General).%New("RULES_ENABLED_INVALID") }
    }
    quit data
}
}
