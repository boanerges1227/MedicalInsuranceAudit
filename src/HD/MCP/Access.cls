Class HD.MCP.Access Extends %RegisteredObject
{
/// Index token identities only by their SHA-256 digests.
ClassMethod Hash(token As %String) As %String { quit $system.Encryption.Base64Encode($system.Encryption.SHAHash(256,token)) }
/// Validate the token and clear the previous request's process context.
ClassMethod Authenticate(token As %String)
{
    kill ^||HDMCP
    if (token="")!($length(token)>512) { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
    set hash=..Hash(token)
    lock +^HDMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try { set actor=..Validate(hash),^||HDMCP("actor")=actor,^||HDMCP("hash")=hash,^HDMCPAccess($namespace,"lastUsed",actor)=##class(HD.MCP.Tokens).Now() }
    catch ex { lock -^HDMCPAccess($namespace,"lock") throw ex }
    lock -^HDMCPAccess($namespace,"lock")
}
/// Check current token status on every call so expiry and revocation take effect immediately.
ClassMethod Validate(hash As %String) As %String
{
    if '##class(HD.MCP.Status).Enabled() { throw ##class(%Exception.General).%New("MCP_SERVICE_DISABLED") }
    set actor=$get(^HDMCPAccess($namespace,"token",hash))
    if actor="" { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
    if '$data(^HDMCPAccess($namespace,"managed",actor)) { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
    set meta={}.%FromJSON(^HDMCPAccess($namespace,"managed",actor))
    if (meta.hash'=hash)!(meta.revokedAtEpoch>0)!((meta.expiresAtEpoch>0)&&(meta.expiresAtEpoch<=##class(HD.MCP.Tokens).Now())) { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
    quit actor
}
/// Recheck the token, case permissions, and expected case version for every tool call.
ClassMethod Check(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    set actor=$get(^||HDMCP("actor")),hash=$get(^||HDMCP("hash"))
    lock +^HDMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        if (actor="")!(..Validate(hash)'=actor) { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
        if '$get(^HDMCPAccess($namespace,"grant",actor,caseId)) { throw ##class(%Exception.General).%New("MCP_CASE_DENIED") }
    } catch ex { lock -^HDMCPAccess($namespace,"lock") throw ex }
    lock -^HDMCPAccess($namespace,"lock")
    set c=##class(HD.Store).Detail(caseId)
    if (expectedVersion<1)!(c.version'=expectedVersion) { throw ##class(%Exception.General).%New("STALE_CASE") }
    quit c
}
}
