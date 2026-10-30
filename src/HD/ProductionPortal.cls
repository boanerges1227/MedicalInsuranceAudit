Class HD.ProductionPortal Extends %RegisteredObject
{
/// Return the fixed IRIS administration URL for the local demo, including the demo account so the embedded
/// portal opens without a second login. Demo-only setting: credentials appear in the URL and browser history.
ClassMethod Target() As %DynamicObject
{
    do ##class(HD.AdminSession).Require()
    set user="medreview"
    set f=##class(%Stream.FileCharacter).%New()
    set sc=f.LinkToFile("/durable/iris/private/med-audit-reviewer-password")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PRODUCTION_CREDENTIALS_UNAVAILABLE") }
    set password=$zstrip(f.ReadLine(),"<>W")
    do f.%Close()
    if $length(password)<16 { throw ##class(%Exception.General).%New("PRODUCTION_CREDENTIALS_INVALID") }
    set url="/csp/"_$zconvert($namespace,"L")_"/EnsPortal.ProductionConfig.zen?$NAMESPACE="_$zconvert($namespace,"O","URL")_"&PRODUCTION=HD.Production"
    set url=url_"&IRISUsername="_$zconvert(user,"O","URL")_"&IRISPassword="_$zconvert(password,"O","URL")
    set password=""
    quit {"url":(url),"namespace":($namespace),"production":"HD.Production"}
}
}