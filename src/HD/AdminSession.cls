Class HD.AdminSession Extends %RegisteredObject
{
/// Use server UTC time to enforce the administrator session idle timeout.
ClassMethod Now() As %Numeric
{
    set stamp=$ztimestamp
    quit (($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
}

/// Accept only sessions created by this project's login endpoint and recheck administrator permissions on every access.
ClassMethod Current() As %DynamicObject
{
    if '$data(%session) { quit {"authenticated":false} }
    if '$isobject(%session) { quit {"authenticated":false} }
    if $get(%session.Data("HDAdminApp"))'=%request.Application { quit {"authenticated":false} }
    if ($get(%session.Data("HDAdminUser"))="")!($get(%session.Data("HDAdminUser"))'=$username) { quit {"authenticated":false} }
    if ..Now()>=+$get(%session.Data("HDAdminDeadline")) { do ..End() quit {"authenticated":false} }
    try { do ##class(HD.AdminSession).RequirePrivileges() } catch ex { return {"authenticated":false} }
    set %session.Data("HDAdminDeadline")=..Now()+%session.Data("HDAdminTimeout")
    quit {"authenticated":true,"username":($username),"idleTimeoutSeconds":(%session.Data("HDAdminTimeout"))}
}

/// Validate the IRIS session and permissions before administrator operations.
ClassMethod Require()
{
    set state=..Current()
    if 'state.authenticated { do ..End() throw ##class(%Exception.General).%New("ADMIN_AUTHENTICATION_REQUIRED") }
    do ##class(HD.AdminSession).RequirePrivileges()
}

/// Authenticate through native IRIS accounts; never log passwords or authentication requests.
ClassMethod Login(data As %DynamicObject) As %DynamicObject
{
    // Allow login only in a newly created IRIS session; the client ends the old anonymous session before submitting credentials once.
    // Avoid private native methods and prevent a known anonymous cookie from being elevated to an admin session.
    if '%session.NewSession { do ..End() throw ##class(%Exception.General).%New("ADMIN_NEW_SESSION_REQUIRED") }
    if (data.%GetTypeOf("username")'="string")!(data.%GetTypeOf("password")'="string") { throw ##class(%Exception.General).%New("ADMIN_LOGIN_FAILED") }
    set username=data.username,password=data.password
    if ($length(username)<1)!($length(username)>128)!($length(password)<1)!($length(password)>2048) { throw ##class(%Exception.General).%New("ADMIN_LOGIN_FAILED") }
    set %session.Data("HDAdminUser")="",%session.Data("HDAdminApp")=""
    set timeout=%session.AppTimeout
    set sc=%session.Logout(1)
    try { set sc=%session.Login(username,password,0,,.appError) } catch ex { set sc=0 }
    set password="",data.password=""
    if (sc'=1)!($system.Status.IsError($get(appError,1))) {
        do ..End()
        throw ##class(%Exception.General).%New("ADMIN_LOGIN_FAILED")
    }
    try { do ##class(HD.AdminSession).RequirePrivileges() } catch ex {
        do ..End()
        throw ##class(%Exception.General).%New("ADMIN_PERMISSION_REQUIRED")
    }
    set %session.Data("HDAdminUser")=$username,%session.Data("HDAdminApp")=%request.Application
    set %session.AppTimeout=$select((timeout>0)&&(timeout<=1800):timeout,1:1800)
    set %session.Data("HDAdminTimeout")=%session.AppTimeout,%session.Data("HDAdminDeadline")=..Now()+%session.AppTimeout
    quit ..Current()
}

/// End the session and reject subsequent access using the old cookie.
ClassMethod End()
{
    set %session.Data("HDAdminUser")="",%session.Data("HDAdminApp")=""
    set %session.Data("HDAdminDeadline")=0
    set sc=%session.Logout(1)
    set %session.EndSession=1
}

/// Allow repeated same-origin logout requests without an active session.
ClassMethod Logout() As %DynamicObject
{
    do ..End()
    quit {"authenticated":false}
}
/// Use existing IRIS administrator permissions for model and token management; grant no anonymous access.
ClassMethod RequirePrivileges()
{
    if '$system.Security.Check("%Admin_ConfigStore","USE") { throw ##class(%Exception.General).%New("FORBIDDEN") }
    if '$system.Security.Check("%Admin_Wallet","USE") { throw ##class(%Exception.General).%New("FORBIDDEN") }
}

}
