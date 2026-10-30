Class HD.MCP.Tokens Extends %RegisteredObject
{
/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Now() As %Integer
{
    set stamp=$ztimestamp
    quit (($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod EnrollLegacy()
{
    quit
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Row(id As %String) As %DynamicObject
{
    if '$data(^HDMCPAccess($namespace,"managed",id)) { throw ##class(%Exception.General).%New("MCP_TOKEN_NOT_FOUND") }
    set meta={}.%FromJSON(^HDMCPAccess($namespace,"managed",id)),cases=[],c="",status="ACTIVE"
    if meta.revokedAtEpoch>0 { set status="REVOKED" } elseif (meta.expiresAtEpoch>0)&&(meta.expiresAtEpoch<=..Now()) { set status="EXPIRED" }
    for { set c=$order(^HDMCPAccess($namespace,"grant",id,c)) quit:c=""  if $get(^HDMCPAccess($namespace,"grant",id,c)) { do cases.%Push(c) } }
    quit {"id":(id),"label":(meta.label),"version":(meta.version),"createdAtEpoch":(meta.createdAtEpoch),"expiresAtEpoch":(meta.expiresAtEpoch),"revokedAtEpoch":(meta.revokedAtEpoch),"lastUsedAtEpoch":(+$get(^HDMCPAccess($namespace,"lastUsed",id))),"status":(status),"legacy":(meta.legacy),"cases":(cases)}
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Catalog() As %DynamicObject
{
    do ##class(HD.AdminSession).RequirePrivileges()
    lock +^HDMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        do ..EnrollLegacy()
        set rows=[],id=""
        for { set id=$order(^HDMCPAccess($namespace,"managed",id)) quit:id=""  do rows.%Push(..Row(id)) }
        set result={"tokens":(rows),"namespace":($namespace),"endpoint":"http://127.0.0.1:52875/mcp"}
    } catch ex { lock -^HDMCPAccess($namespace,"lock") throw ex }
    lock -^HDMCPAccess($namespace,"lock")
    quit result
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Label(data As %DynamicObject) As %String
{
    if data.%GetTypeOf("label")'="string" { throw ##class(%Exception.General).%New("INVALID_MCP_LABEL") }
    set label=data.label
    if ($length($zstrip(label,"<>W"))=0)!($length(label)>80) { throw ##class(%Exception.General).%New("INVALID_MCP_LABEL") }
    for i=1:1:$length(label) { if ($ascii(label,i)<32)!($ascii(label,i)=127) { throw ##class(%Exception.General).%New("INVALID_MCP_LABEL") } }
    quit label
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Cases(data As %DynamicObject) As %DynamicArray
{
    if data.%GetTypeOf("cases")'="array" { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
    set input=data.cases,result=[]
    if input.%Size()>50 { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
    for i=0:1:input.%Size()-1 {
        if input.%GetTypeOf(i)'="string" { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
        set id=input.%Get(i)
        if ($length(id)>64)!(id="")!(id["/") { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
        if '$data(^HDData("case",id)) { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
        if '$data(seen(id)) { set seen(id)=1 do result.%Push(id) }
    }
    quit result
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Create(data As %DynamicObject) As %DynamicObject
{
    do ##class(HD.AdminSession).RequirePrivileges()
    set label=..Label(data),cases=..Cases(data)
    if data.%GetTypeOf("expiresInDays")'="number" { throw ##class(%Exception.General).%New("INVALID_MCP_EXPIRY") }
    set days=data.expiresInDays
    if (days<1)!(days>365)!(days\1'=days) { throw ##class(%Exception.General).%New("INVALID_MCP_EXPIRY") }
    set token="hd_mcp_"_$translate($system.Encryption.Base64Encode($system.Encryption.GenCryptRand(32)),"+/=","-_"),hash=##class(HD.MCP.Access).Hash(token)
    lock +^HDMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    tstart
    try {
        set id="t"_$increment(^HDMCPAccess($namespace,"seq")),now=..Now()
        set meta={"id":(id),"label":(label),"hash":(hash),"version":1,"createdAtEpoch":(now),"expiresAtEpoch":(now+(days*86400)),"revokedAtEpoch":0,"legacy":false}
        set ^HDMCPAccess($namespace,"managed",id)=meta.%ToJSON(),^HDMCPAccess($namespace,"token",hash)=id,^HDMCPAccess($namespace,"actorToken",id)=hash
        do ..WriteCases(id,cases),..Audit("CREATE",id,1)
        set result={"item":(..Row(id)),"token":(token)}
        tcommit
    } catch ex { trollback 1 lock -^HDMCPAccess($namespace,"lock") throw ex }
    lock -^HDMCPAccess($namespace,"lock")
    quit result
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Current(id As %String, data As %DynamicObject) As %DynamicObject
{
    if '$data(^HDMCPAccess($namespace,"managed",id)) { throw ##class(%Exception.General).%New("MCP_TOKEN_NOT_FOUND") }
    set meta={}.%FromJSON(^HDMCPAccess($namespace,"managed",id))
    if (data.%GetTypeOf("version")'="number")||(data.%Get("version",0)'=meta.version) { throw ##class(%Exception.General).%New("MCP_TOKEN_VERSION_CONFLICT") }
    if meta.revokedAtEpoch>0 { throw ##class(%Exception.General).%New("MCP_TOKEN_REVOKED") }
    quit meta
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Update(id As %String, data As %DynamicObject) As %DynamicObject
{
    do ##class(HD.AdminSession).RequirePrivileges()
    set label=..Label(data),cases=..Cases(data)
    lock +^HDMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    tstart
    try {
        do ..EnrollLegacy()
        set meta=..Current(id,data),meta.label=label,meta.version=meta.version+1
        set ^HDMCPAccess($namespace,"managed",id)=meta.%ToJSON()
        do ..WriteCases(id,cases),..Audit("UPDATE",id,meta.version)
        set result=..Row(id)
        tcommit
    } catch ex { trollback 1 lock -^HDMCPAccess($namespace,"lock") throw ex }
    lock -^HDMCPAccess($namespace,"lock")
    quit result
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Revoke(id As %String, data As %DynamicObject) As %DynamicObject
{
    do ##class(HD.AdminSession).RequirePrivileges()
    lock +^HDMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    tstart
    try {
        do ..EnrollLegacy()
        set meta=..Current(id,data),meta.revokedAtEpoch=..Now(),meta.version=meta.version+1
        set ^HDMCPAccess($namespace,"managed",id)=meta.%ToJSON()
        kill ^HDMCPAccess($namespace,"token",meta.hash),^HDMCPAccess($namespace,"grant",id)
        do ..Audit("REVOKE",id,meta.version)
        set result=..Row(id)
        tcommit
    } catch ex { trollback 1 lock -^HDMCPAccess($namespace,"lock") throw ex }
    lock -^HDMCPAccess($namespace,"lock")
    quit result
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod WriteCases(id As %String, cases As %DynamicArray)
{
    kill ^HDMCPAccess($namespace,"grant",id)
    for i=0:1:cases.%Size()-1 { set ^HDMCPAccess($namespace,"grant",id,cases.%Get(i))=1 }
}

/// Enforce identity, permissions, and data boundaries for medical audit MCP management.
ClassMethod Audit(action As %String, id As %String, version As %Integer)
{
    set n=$increment(^HDMCPAccess($namespace,"managementAuditSeq"))
    set ^HDMCPAccess($namespace,"managementAudit",n)={"action":(action),"tokenId":(id),"version":(version),"actor":($username),"occurredAtEpoch":(..Now())}.%ToJSON()
}
}
