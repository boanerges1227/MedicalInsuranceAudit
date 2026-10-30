Class HD.EmbeddedVector Extends %RegisteredObject
{
/// Send the query to a single-process Production operation to avoid loading the model in every CSP process.
ClassMethod Encode(text As %String, query As %Boolean = 0) As %String
{
    set fallback={"status":"FAILED","code":"EMBEDDING_UNAVAILABLE"},id=""
    if (text="")!($length(text)>4096) { set fallback.code="INVALID_INPUT" quit fallback.%ToJSON() }
    // Purge short-lived queries left behind by abnormal process exits; the temp global is not recorded as Production messages.
    do ..PurgeExpired()
    set id=$system.Encryption.Base32HexEncode($system.Encryption.GenCryptRand(24,1),1),now=($piece($horolog,",",1)*86400)+$piece($horolog,",",2)
    set ^CacheTempUserMedAudit($namespace,id,"created")=now,^CacheTempUserMedAudit($namespace,id,"text")=text,^CacheTempUserMedAudit($namespace,id,"query")=+query
    try {
        set sc=##class(Ens.Director).CreateBusinessService("FHIRIntake",.service)
        if $system.Status.IsOK(sc) {
            set request=##class(HD.Request).%New(),request.Payload=id
            set sc=service.SendRequestSync("EmbeddedVector",request,.response,60)
            if $system.Status.IsOK(sc),$isobject(response) { set result=response.Payload }
        }
    } catch ex { set result="" }
    // Delete only this request's random id; a queued message after timeout simply gets a no-data failure.
    kill ^CacheTempUserMedAudit($namespace,id)
    if $get(result)="" { set result=fallback.%ToJSON() }
    quit result
}

/// Remove leftover queries older than 120 seconds; normal requests are cleaned up right after completion or timeout.
ClassMethod PurgeExpired()
{
    lock +^CacheTempUserMedAudit($namespace,"purge"):1 if '$test { quit }
    set now=($piece($horolog,",",1)*86400)+$piece($horolog,",",2),id=""
    for  { set id=$order(^CacheTempUserMedAudit($namespace,id)) quit:id=""  if id'="purge",+$get(^CacheTempUserMedAudit($namespace,id,"created"))>0,now-+$get(^CacheTempUserMedAudit($namespace,id,"created"))>120 { kill ^CacheTempUserMedAudit($namespace,id) } }
    lock -^CacheTempUserMedAudit($namespace,"purge")
}

/// Generate a 512-dimensional vector for a single text in the IRIS process using the pinned Chinese model.
ClassMethod EncodePython(text As %String, query As %Boolean = 0) As %String [ Language = python ]
{
    import json
    import site
    import sys
    try:
        # 使用上传工作进程安装在持久卷中的依赖；Python 版本不匹配时返回失败。
        packages = '/durable/iris/private/upload-python/lib/python%d.%d/site-packages' % sys.version_info[:2]
        site.addsitedir(packages)
        import iris
        # 从 ZPM 安装资源目录加载模型辅助模块。
        tools_dir = str(iris.cls("HD.PackageSetup").Root()) + "tools"
        if tools_dir not in sys.path:
            sys.path.insert(0, tools_dir)
        import embedded_vectors
        data = json.loads(embedded_vectors.encode_json(json.dumps([text], ensure_ascii=False), int(query) == 1))
        values = data['vectors'][0]
        if len(values) != 512:
            raise ValueError('INVALID_DIMENSION')
        # 与 IRIS TO_VECTOR 参数一致；格式化后不输出原始文本。
        csv = ','.join(format(float(value), '.9g') for value in values)
        return json.dumps({'status': 'OK', 'dimensions': 512, 'model_hash': data['model_hash'], 'vector_csv': csv})
    except Exception as exc:
        # 避免将文档内容和服务器文件路径写入结果。
        code = 'INVALID_INPUT' if isinstance(exc, (ValueError, TypeError)) else 'EMBEDDING_UNAVAILABLE'
        return json.dumps({'status': 'FAILED', 'code': code})
}
}
