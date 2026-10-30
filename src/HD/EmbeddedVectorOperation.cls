Class HD.EmbeddedVectorOperation Extends Ens.BusinessOperation
{
/// Read only the temporary query for the random id; the actual model runs in a single Production operation process.
Method OnMessage(request As HD.Request, Output response As HD.Reply) As %Status
{
    set response=##class(HD.Reply).%New(),id=request.Payload
    set fallback={"status":"FAILED","code":"EMBEDDING_UNAVAILABLE"}
    if (id="")!('$data(^CacheTempUserMedAudit($namespace,id,"text"))) { set response.Payload=fallback.%ToJSON() quit 1 }
    set text=$get(^CacheTempUserMedAudit($namespace,id,"text")),query=+$get(^CacheTempUserMedAudit($namespace,id,"query"))
    try { set response.Payload=##class(HD.EmbeddedVector).EncodePython(text,query) } catch ex { set response.Payload=fallback.%ToJSON() }
    quit 1
}
}
