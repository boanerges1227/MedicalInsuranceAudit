Class HD.AdminREST Extends %CSP.REST
{
Parameter CHARSET = "utf-8";
Parameter HandleCorsRequest = 0;
Parameter UseSession As Integer = 1;
XData UrlMap
{
<Routes>
 <Route Url="/session" Method="GET" Call="Session"/>
 <Route Url="/login" Method="POST" Call="Login"/>
 <Route Url="/logout" Method="POST" Call="Logout"/>
 <Route Url="/models" Method="GET" Call="Models"/>
 <Route Url="/models" Method="POST" Call="SaveModel"/>
 <Route Url="/models/:id/activate" Method="POST" Call="ActivateModel"/>
 <Route Url="/mcp-tokens" Method="GET" Call="Tokens"/>
 <Route Url="/mcp-tokens" Method="POST" Call="CreateToken"/>
 <Route Url="/mcp-tokens/:id" Method="POST" Call="UpdateToken"/>
 <Route Url="/mcp-tokens/:id/revoke" Method="POST" Call="RevokeToken"/>
</Routes>
}
/// Set the HttpOnly attribute on the session cookie.
ClassMethod OnPreHTTP() As %Boolean { set %response.UseHttpOnly=1 quit ##super() }
/// Return session status only, without cookies or passwords.
ClassMethod Session() As %Status { quit ##class(HD.REST).Json(##class(HD.AdminSession).Current()) }
/// Require the same-origin header check and create a new session for login requests.
ClassMethod Login() As %Status
{
    try { set data=##class(HD.REST).Body(),result=##class(HD.AdminSession).Login(data) } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// End the current administrator session.
ClassMethod Logout() As %Status
{
    try { set data=##class(HD.REST).Body(),result=##class(HD.AdminSession).Logout() } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// Require a native administrator session before returning model management data.
ClassMethod Models() As %Status
{
    try { do ##class(HD.AdminSession).Require() set result=##class(HD.ModelSettings).Catalog() } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// Allow only administrators to write project configuration; store keys in IRIS Wallet.
ClassMethod SaveModel() As %Status
{
    try { do ##class(HD.AdminSession).Require() set result=##class(HD.ModelSettings).Save(##class(HD.REST).Body()) } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// Require the previously read configuration version for activation; do not call the model.
ClassMethod ActivateModel(id As %String) As %Status
{
    try { do ##class(HD.AdminSession).Require() set body=##class(HD.REST).Body(),result=##class(HD.ModelSettings).Activate(id,body.%Get("version",-1)) } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// Require a native administrator session before listing MCP tokens.
ClassMethod Tokens() As %Status
{
    try { do ##class(HD.AdminSession).Require() set result=##class(HD.MCP.Tokens).Catalog() } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// Return a new token in plaintext once; persist only its digest.
ClassMethod CreateToken() As %Status
{
    try { do ##class(HD.AdminSession).Require() set result=##class(HD.MCP.Tokens).Create(##class(HD.REST).Body()) } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// Check the version before changing a token's case permissions.
ClassMethod UpdateToken(id As %String) As %Status
{
    try { do ##class(HD.AdminSession).Require() set result=##class(HD.MCP.Tokens).Update(id,##class(HD.REST).Body()) } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// Revalidate revoked tokens on every tool call.
ClassMethod RevokeToken(id As %String) As %Status
{
    try { do ##class(HD.AdminSession).Require() set result=##class(HD.MCP.Tokens).Revoke(id,##class(HD.REST).Body()) } catch ex { return ..AdminError(ex.Name) }
    quit ##class(HD.REST).Json(result)
}
/// Return authentication failures as HTTP 401/403 without a Basic authentication prompt.
ClassMethod AdminError(code As %String) As %Status
{
    if code="ADMIN_AUTHENTICATION_REQUIRED" { set %response.Status="401 Unauthorized" return ##class(HD.REST).Json({"error":(code)}) }
    if (code="ADMIN_LOGIN_FAILED")!(code="ADMIN_PERMISSION_REQUIRED")!(code="FORBIDDEN") { set %response.Status="403 Forbidden" return ##class(HD.REST).Json({"error":(code)}) }
    quit ##class(HD.REST).RespondError(code)
}
}
