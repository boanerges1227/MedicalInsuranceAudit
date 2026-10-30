Class HD.KnowledgePublish Extends %RegisteredObject
{
/// Return the knowledge publication summary for an upload job; the UI must derive available actions only from server state.
ClassMethod Summary(id As %Integer) As %DynamicObject
{
    set uploadState=$get(^HDUpload("job",id,"state")),state=$get(^HDUpload("publish",id,"state"))
    if uploadState'="SUCCEEDED" { set state="NOT_READY" }
    if state="" { set state="REVIEW_REQUIRED" }
    quit {"state":(state),"publishedAt":($get(^HDUpload("publish",id,"publishedAt"))),"publishedBy":($get(^HDUpload("publish",id,"publishedBy"))),"withdrawnAt":($get(^HDUpload("publish",id,"withdrawnAt")))}
}

/// Read vector chunks and extract fixed Markdown metadata; automatically extracted values remain a draft for human review.
ClassMethod Preview(id As %String) As %DynamicObject
{
    do ..RequireSucceeded(id)
    set draft=$get(^HDUpload("publish",id,"draft"))
    if draft'="" { set metadata={}.%FromJSON(draft) }
    else {
        set metadata=..Extract(..HeaderText(+id))
    }
    set issues=..Validate(metadata),summary=..Summary(+id)
    quit {"jobId":(+id),"filename":($get(^HDUpload("job",id,"filename"))),"metadata":(metadata),"issues":(issues),"publication":(summary),"excerpt":(..Excerpt(+id))}
}

/// Save the administrator-reviewed draft; mark it publishable only after validation and explicit confirmation.
ClassMethod Save(id As %String, body As %DynamicObject, reviewer As %String) As %DynamicObject
{
    do ..RequireSucceeded(id)
    if reviewer="" { throw ##class(%Exception.General).%New("FORBIDDEN") }
    if $get(^HDUpload("publish",id,"state"))="PUBLISHED" { throw ##class(%Exception.General).%New("KNOWLEDGE_ALREADY_PUBLISHED") }
    set metadata=..Normalize(body),issues=..Validate(metadata),confirmed=+metadata.%Get("confirmed")
    if metadata.%Get("needsReview",1) { set state="REVIEW_REQUIRED" }
    elseif 'confirmed { set state="REVIEW_REQUIRED" }
    elseif issues.%Size()>0 { set state="REVIEW_REQUIRED" }
    else { set state="READY" }
    set ^HDUpload("publish",id,"draft")=metadata.%ToJSON(),^HDUpload("publish",id,"state")=state,^HDUpload("publish",id,"reviewedBy")=reviewer,^HDUpload("publish",id,"reviewedAt")=$ztimestamp
    quit {"jobId":(+id),"state":(state),"issues":(issues),"metadata":(metadata)}
}

/// Reuse uploaded vectors in one transaction and use content and metadata fingerprints to make repeated publication idempotent.
ClassMethod Publish(id As %String, body As %DynamicObject, reviewer As %String) As %DynamicObject
{
    do ..RequireSucceeded(id)
    if reviewer="" { throw ##class(%Exception.General).%New("FORBIDDEN") }
    lock +^HDUpload("publish",id):10 if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set draft=$get(^HDUpload("publish",id,"draft"))
        if draft="" { throw ##class(%Exception.General).%New("KNOWLEDGE_NOT_READY") }
        set metadata={}.%FromJSON(draft),issues=..Validate(metadata)
        if issues.%Size()>0 { throw ##class(%Exception.General).%New("KNOWLEDGE_NOT_READY") }
        set version=..ContentVersion(+id,metadata),state=$get(^HDUpload("publish",id,"state"))
        if state="PUBLISHED" {
            if $get(^HDUpload("publish",id,"version"))'=version { throw ##class(%Exception.General).%New("KNOWLEDGE_VERSION_CONFLICT") }
            set result={"jobId":(+id),"state":"PUBLISHED","chunks":(+$get(^HDUpload("publish",id,"chunks"))),"idempotent":true}
        } else {
            if state'="READY" { throw ##class(%Exception.General).%New("KNOWLEDGE_NOT_READY") }
            set sourcePath=..SourcePath(+id),publishedAt=$ztimestamp,publishedMeta=..PublicationMetadata(+id,metadata,sourcePath,publishedAt,reviewer)
            // The HTTP publication path must check the schema silently so setup logs cannot contaminate the JSON response.
            do ##class(HD.NationalVector).Install(1)
            set check=##class(%SQL.Statement).%New(),sc=check.%Prepare("SELECT COUNT(*) AS total FROM HD.NationalVectors WHERE SourcePath = ?")
            if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("KNOWLEDGE_QUERY_FAILED") }
            set rs=check.%Execute(sourcePath) if 'rs.%Next() { throw ##class(%Exception.General).%New("KNOWLEDGE_QUERY_FAILED") }
            if rs.%Get("total")>0 { throw ##class(%Exception.General).%New("KNOWLEDGE_VERSION_CONFLICT") }
            set rows=##class(%SQL.Statement).%New(),sc=rows.%Prepare("SELECT ChunkIndex,TextHash,ModelHash FROM HD.UploadedVectors WHERE JobId = ? ORDER BY ChunkIndex")
            if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("KNOWLEDGE_QUERY_FAILED") }
            set put=##class(%SQL.Statement).%New(),put.%SelectMode=1,sc=put.%Prepare("INSERT INTO HD.NationalVectors (ChunkId,TextHash,ModelHash,SourcePath,ChunkText,Metadata,Embedding) SELECT ?,TextHash,ModelHash,?,ChunkText,?,Embedding FROM HD.UploadedVectors WHERE JobId = ? AND ChunkIndex = ?")
            if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("KNOWLEDGE_INSERT_FAILED") }
            tstart
            try {
                set rs=rows.%Execute(+id),count=0,model=""
                while rs.%Next() {
                    set index=+rs.%Get("ChunkIndex"),rowModel=rs.%Get("ModelHash")
                    if (model'="")&&(model'=rowModel) { throw ##class(%Exception.General).%New("KNOWLEDGE_MODEL_CONFLICT") }
                    set model=rowModel,chunkId="upload-"_id_"-"_index,insert=put.%Execute(chunkId,sourcePath,publishedMeta.%ToJSON(),+id,index)
                    if insert.%SQLCODE<0 { throw ##class(%Exception.General).%New("KNOWLEDGE_INSERT_FAILED") }
                    set count=count+1
                }
                if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("KNOWLEDGE_QUERY_FAILED") }
                if (count<1)!(count'=+$get(^HDUpload("job",id,"chunks"))) { throw ##class(%Exception.General).%New("KNOWLEDGE_CHUNK_CONFLICT") }
                set ^HDUpload("publish",id,"state")="PUBLISHED",^HDUpload("publish",id,"publishedAt")=publishedAt,^HDUpload("publish",id,"publishedBy")=reviewer,^HDUpload("publish",id,"version")=version,^HDUpload("publish",id,"chunks")=count,^HDUpload("publish",id,"sourcePath")=sourcePath
                set ^HDUpload("publish",id,"audit",$increment(^HDUpload("publish","auditCounter")))={"action":"PUBLISH","jobId":(+id),"by":(reviewer),"at":(publishedAt),"version":(version)}.%ToJSON()
                tcommit
            } catch inner {
                trollback
                throw inner
            }
            set result={"jobId":(+id),"state":"PUBLISHED","chunks":(count),"idempotent":false,"publishedAt":(publishedAt),"publishedBy":(reviewer)}
        }
    } catch ex { lock -^HDUpload("publish",id) throw ex }
    lock -^HDUpload("publish",id)
    quit result
}

/// Publish reviewed jobs one by one and return each result; one failure must not be presented as whole-batch success.
ClassMethod PublishBatch(body As %DynamicObject, reviewer As %String) As %DynamicObject
{
    if reviewer="" { throw ##class(%Exception.General).%New("FORBIDDEN") }
    set jobs=body.%Get("jobIds","")
    if '$isobject(jobs) { throw ##class(%Exception.General).%New("INVALID_PUBLISH_BATCH") }
    if (jobs.%Size()<1)!(jobs.%Size()>100) { throw ##class(%Exception.General).%New("INVALID_PUBLISH_BATCH") }
    set results=[],succeeded=0,failed=0
    for i=0:1:jobs.%Size()-1 {
        set id=jobs.%Get(i)
        try { set item=..Publish(id,{},reviewer),succeeded=succeeded+1 }
        catch ex { set item={"jobId":(+id),"state":"FAILED","error":(ex.Name)},failed=failed+1 }
        do results.%Push(item)
    }
    quit {"results":(results),"succeeded":(succeeded),"failed":(failed)}
}

/// Withdraw published knowledge chunks while retaining upload vectors, drafts, and audit records for later review.
ClassMethod Withdraw(id As %String, body As %DynamicObject, reviewer As %String) As %DynamicObject
{
    do ..RequireSucceeded(id)
    if reviewer="" { throw ##class(%Exception.General).%New("FORBIDDEN") }
    set reason=$zstrip(body.%Get("reason",""),"<>W")
    if (reason="")!($length(reason)>500) { throw ##class(%Exception.General).%New("WITHDRAW_REASON_REQUIRED") }
    lock +^HDUpload("publish",id):10 if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        if $get(^HDUpload("publish",id,"state"))'="PUBLISHED" { throw ##class(%Exception.General).%New("KNOWLEDGE_NOT_PUBLISHED") }
        set sourcePath=$get(^HDUpload("publish",id,"sourcePath"))
        if sourcePath="" { throw ##class(%Exception.General).%New("KNOWLEDGE_VERSION_CONFLICT") }
        set del=##class(%SQL.Statement).%New(),sc=del.%Prepare("DELETE FROM HD.NationalVectors WHERE SourcePath = ?")
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("KNOWLEDGE_DELETE_FAILED") }
        tstart
        try {
            set rs=del.%Execute(sourcePath)
            if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("KNOWLEDGE_DELETE_FAILED") }
            set withdrawnAt=$ztimestamp,^HDUpload("publish",id,"state")="WITHDRAWN",^HDUpload("publish",id,"withdrawnAt")=withdrawnAt,^HDUpload("publish",id,"withdrawnBy")=reviewer,^HDUpload("publish",id,"withdrawReason")=reason
            set ^HDUpload("publish",id,"audit",$increment(^HDUpload("publish","auditCounter")))={"action":"WITHDRAW","jobId":(+id),"by":(reviewer),"at":(withdrawnAt),"reason":(reason)}.%ToJSON()
            tcommit
        } catch inner {
            trollback
            throw inner
        }
    } catch ex { lock -^HDUpload("publish",id) throw ex }
    lock -^HDUpload("publish",id)
    quit {"jobId":(+id),"state":"WITHDRAWN","withdrawnAt":(withdrawnAt),"withdrawnBy":(reviewer)}
}

/// Validate every required publication field and return all issues without relying on UI checks to protect the knowledge library.
ClassMethod Validate(metadata As %DynamicObject) As %DynamicArray
{
    set issues=[]
    if metadata.%Get("sourceId","")="" { do issues.%Push("SOURCE_ID_REQUIRED") }
    if metadata.%Get("title","")="" { do issues.%Push("TITLE_REQUIRED") }
    if metadata.%Get("region","")="" { do issues.%Push("REGION_REQUIRED") }
    set recordType=metadata.%Get("recordType","")
    if recordType="" { do issues.%Push("RECORD_TYPE_REQUIRED") }
    elseif '$listfind($listfromstring("policy,attachment,supplement"),recordType) { do issues.%Push("INVALID_RECORD_TYPE") }
    set url=metadata.%Get("sourceUrl","")
    if (url="")!(($extract(url,1,7)'="http://")&&($extract(url,1,8)'="https://"))!(url[" ")!(url[$char(10))!(url[$char(13))!($length($piece(url,"/",3))<1) { do issues.%Push("INVALID_SOURCE_URL") }
    set publicationDate=metadata.%Get("publicationDate","")
    if publicationDate="" { do issues.%Push("PUBLICATION_DATE_REQUIRED") }
    elseif '..ValidDate(publicationDate) { do issues.%Push("INVALID_PUBLICATION_DATE") }
    set effectiveDate=metadata.%Get("effectiveDate","")
    if (effectiveDate="")&&(metadata.%Get("effectiveStatus","")="") { do issues.%Push("EFFECTIVE_STATUS_REQUIRED") }
    elseif (effectiveDate'="")&&('..ValidDate(effectiveDate)) { do issues.%Push("INVALID_EFFECTIVE_DATE") }
    if metadata.%Get("needsReview",1) { do issues.%Push("KNOWLEDGE_REVIEW_REQUIRED") }
    if 'metadata.%Get("confirmed",0) { do issues.%Push("KNOWLEDGE_CONFIRMATION_REQUIRED") }
    set parents=metadata.%Get("parentPolicyIds",[]),parentSize=0,parentInvalid=0
    if '$isobject(parents) { set parentInvalid=1 }
    else {
        set parentSize=parents.%Size() if parentSize>100 { set parentInvalid=1 }
        for i=0:1:parentSize-1 { set parent=parents.%Get(i) if $isobject(parent)!($length(parent)>128) { set parentInvalid=1 quit } }
    }
    if ($length(metadata.%Get("sourceId",""))>128)!($length(metadata.%Get("title",""))>500)!($length(metadata.%Get("region",""))>80)!($length(recordType)>80)!($length(url)>2048)!($length(publicationDate)>32)!($length(effectiveDate)>32)!($length(metadata.%Get("effectiveStatus",""))>200)!($length(metadata.%Get("exceptionConditions",""))>4000)!($length(metadata.%Get("sourceSha256",""))>4000)!($length(metadata.%Get("reviewNote",""))>4000)!(parentInvalid) { do issues.%Push("KNOWLEDGE_METADATA_TOO_LONG") }
    quit issues
}

/// Validate that an ISO date has the required format and resolves to a real calendar date.
ClassMethod ValidDate(value As %String) As %Boolean
{
    if value'?4N1"-"2N1"-"2N { quit 0 }
    set valid=1
    try { set day=$zdateh(value,3) } catch ex { set valid=0 }
    if 'valid { quit 0 }
    quit day>0
}

/// Normalize page input by copying only allowed publication fields and ignoring forged publisher or state values.
ClassMethod Normalize(body As %DynamicObject) As %DynamicObject
{
    set data={}
    for key="sourceId","title","region","recordType","sourceUrl","publicationDate","effectiveDate","effectiveStatus","exceptionConditions","sourceSha256","reviewNote" { do data.%Set(key,$zstrip(body.%Get(key,""),"<>W")) }
    set parents=body.%Get("parentPolicyIds",[])
    if '$isobject(parents) { set parents=[] }
    do data.%Set("parentPolicyIds",parents),data.%Set("needsReview",+body.%Get("needsReview",1)),data.%Set("confirmed",+body.%Get("confirmed",0))
    quit data
}

/// Extract metadata from the controlled Markdown header and ignore unknown fields instead of executing or interpreting them.
ClassMethod Extract(text As %String) As %DynamicObject
{
    set raw={},title="",lineCount=$length(text,$char(10))
    for i=1:1:$select(lineCount>80:80,1:lineCount) {
        set line=$zstrip($piece(text,$char(10),i),"<>W")
        if ($extract(line,1,2)="##") { quit }
        if ($extract(line,1,2)="# ")&&(title="") { set title=$zstrip($extract(line,3,*),"<>W") continue }
        if $extract(line,1,2)'="- " { continue }
        set pair=$extract(line,3,*),pos=$find(pair,":") if pos<2 { continue }
        set key=$zstrip($extract(pair,1,pos-2),"<>W"),value=..Unquote($zstrip($extract(pair,pos,*),"<>W"))
        do raw.%Set(key,value)
    }
    set role=raw.%Get("document_role",""),recordType=$select(role["附件":"attachment",role["补充":"supplement",1:"policy")
    set parentIds=[] if raw.%Get("parent_id","")'="" { do parentIds.%Push(raw.%Get("parent_id")) }
    set result={"sourceId":(raw.%Get("document_id","")),"title":(raw.%Get("title",title)),"region":(raw.%Get("region","")),"recordType":(recordType),"sourceUrl":(raw.%Get("source_url","")),"publicationDate":(raw.%Get("publication_date","")),"effectiveDate":(raw.%Get("effective_date","")),"effectiveStatus":(raw.%Get("applicability_note","")),"exceptionConditions":(raw.%Get("applicability_note","")),"parentPolicyIds":(parentIds),"sourceSha256":(raw.%Get("source_sha256","")),"needsReview":($select($zconvert(raw.%Get("needs_review","true"),"L")="false":0,1:1)),"reviewNote":(raw.%Get("rule_release_status","")),"confirmed":false}
    quit result
}

/// Reassemble the Markdown header in chunk order so fixed-length vector chunks cannot truncate URLs or review flags.
ClassMethod HeaderText(id As %Integer) As %String
{
    set st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT ChunkText FROM HD.UploadedVectors WHERE JobId = ? ORDER BY ChunkIndex")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("KNOWLEDGE_SOURCE_UNAVAILABLE") }
    set rs=st.%Execute(id),text="",found=0
    for {
        if 'rs.%Next() { quit }
        set text=text_rs.%Get("ChunkText"),found=1
        if text[($char(10)_"## ") { quit }
        if $length(text)>16000 { set text=$extract(text,1,16000) quit }
    }
    if (rs.%SQLCODE<0)!('found) { throw ##class(%Exception.General).%New("KNOWLEDGE_SOURCE_UNAVAILABLE") }
    quit text
}

/// Generate a stable knowledge source path while treating the filename as display-only data and blocking path traversal.
ClassMethod SourcePath(id As %Integer) As %String
{
    set name=$get(^HDUpload("job",id,"filename"))
    if (name="")!(name["/")!(name["\") { throw ##class(%Exception.General).%New("INVALID_UPLOAD") }
    quit "published-upload/"_id_"/"_name
}

/// Compute a version fingerprint from all chunk hashes, model fingerprints, and reviewed metadata to prevent silent overwrites.
ClassMethod ContentVersion(id As %Integer, metadata As %DynamicObject) As %String
{
    set st=##class(%SQL.Statement).%New(),sc=st.%Prepare("SELECT ChunkIndex,TextHash,ModelHash FROM HD.UploadedVectors WHERE JobId = ? ORDER BY ChunkIndex")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("KNOWLEDGE_QUERY_FAILED") }
    set rs=st.%Execute(id),material=metadata.%ToJSON(),count=0,model=""
    while rs.%Next() {
        set rowModel=rs.%Get("ModelHash")
        if (model'="")&&(model'=rowModel) { throw ##class(%Exception.General).%New("KNOWLEDGE_MODEL_CONFLICT") }
        set model=rowModel,material=material_"|"_rs.%Get("ChunkIndex")_":"_rs.%Get("TextHash")_":"_rowModel,count=count+1
    }
    if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("KNOWLEDGE_QUERY_FAILED") }
    if (count<1)!(count'=+$get(^HDUpload("job",id,"chunks"))) { throw ##class(%Exception.General).%New("KNOWLEDGE_CHUNK_CONFLICT") }
    quit $system.Encryption.Base64Encode($system.Encryption.SHAHash(256,material))
}

/// Build a knowledge-library metadata snapshot whose publisher and state are written only by the server.
ClassMethod PublicationMetadata(id As %Integer, metadata As %DynamicObject, sourcePath As %String, publishedAt As %String, reviewer As %String) As %DynamicObject
{
    set flags=[] if metadata.%Get("reviewNote","")'="" { do flags.%Push(metadata.%Get("reviewNote")) }
    set result={"original_path":(sourcePath),"source_id":(metadata.%Get("sourceId")),"title":(metadata.%Get("title")),"region":(metadata.%Get("region")),"record_type":(metadata.%Get("recordType")),"parent_policy_ids":(metadata.%Get("parentPolicyIds",[])),"source_url":(metadata.%Get("sourceUrl")),"source_sha256":(metadata.%Get("sourceSha256")),"dates":{"publication_date":(metadata.%Get("publicationDate")),"effective_date":(metadata.%Get("effectiveDate")),"effective_status":(metadata.%Get("effectiveStatus"))},"exception_conditions":(metadata.%Get("exceptionConditions")),"review_flags":(flags),"needsReview":false,"publicationStatus":"PUBLISHED","publishedAt":(publishedAt),"publishedBy":(reviewer),"sourceJobId":(id)}
    quit result
}

/// Remove one layer of JSON-style quotes while preserving the content for human review.
ClassMethod Unquote(value As %String) As %String
{
    if ($length(value)>1)&&($extract(value,1)="""")&&($extract(value,*)="""") { quit $extract(value,2,*-1) }
    quit value
}

/// Return a short source excerpt for publisher review; the page must still render it through text nodes.
ClassMethod Excerpt(id As %Integer) As %String
{
    set text=""
    try { set text=..HeaderText(id) } catch ex { set text="" }
    quit $extract(text,1,800)
}

/// Allow only successfully vectorized files with valid job identifiers to enter publication review.
ClassMethod RequireSucceeded(id As %String)
{
    if id'?1.N { throw ##class(%Exception.General).%New("INVALID_UPLOAD") }
    if '$data(^HDUpload("job",id)) { throw ##class(%Exception.General).%New("UPLOAD_NOT_FOUND") }
    if $get(^HDUpload("job",id,"state"))'="SUCCEEDED" { throw ##class(%Exception.General).%New("KNOWLEDGE_UPLOAD_NOT_READY") }
}
}
