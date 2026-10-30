Class HD.DemoSetup Extends %RegisteredObject
{
/// Create the local demo administrator once; generate the password in the isolated volume and keep it out of logs.
ClassMethod EnsureReviewer()
{
    new $namespace set $namespace="%SYS",name="medreview"
    if ##class(Security.Users).Exists(name) { quit }
    set f=##class(%Stream.FileCharacter).%New(),sc=f.LinkToFile("/durable/iris/private/med-audit-reviewer-password")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("REVIEWER_PASSWORD_UNAVAILABLE") }
    set password=f.ReadLine()
    if $length(password)<16 { throw ##class(%Exception.General).%New("REVIEWER_PASSWORD_INVALID") }
    set user("Roles")="%All",user("Password")=password,user("Enabled")=1,user("ChangePassword")=0
    set sc=##class(Security.Users).Create(name,.user),password=""
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
}
}
