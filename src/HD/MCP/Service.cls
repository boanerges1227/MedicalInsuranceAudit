Class HD.MCP.Service Extends %AI.MCP.Service
{
Parameter SPECIFICATION As STRING = "HD.MCP.ReadTools";
/// Accept only the dedicated medical audit MCP Bearer credential.
ClassMethod OnAuthenticate(authType As %String, auth As %String, headers As %DynamicObject = "") As %Status
{
    kill ^||HDMCP
    try {
        if $zconvert(authType,"L")'="bearer" { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
        do ##class(HD.MCP.Access).Authenticate(auth)
        return 1
    } catch ex { return $system.Status.Error(5001,"MCP_UNAUTHORIZED") }
}
/// Clear temporary token context when the request ends.
ClassMethod OnPostDispatch(pUrl As %String, pMethod As %String, pSC As %Status) As %Status { kill ^||HDMCP quit 1 }
/// Clear temporary token context when the connection closes.
Method OnPostServer() As %Status { kill ^||HDMCP quit 1 }
}
