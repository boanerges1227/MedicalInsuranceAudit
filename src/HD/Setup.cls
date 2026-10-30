Class HD.Setup Extends %RegisteredObject
{
/// Install isolated CSP applications and Production for this demo without affecting other projects' containers.
ClassMethod Install()
{
    new $namespace
    set $namespace="%SYS",name="/med-audit"
    set p("NameSpace")="USER",p("DispatchClass")="HD.REST",p("AutheEnabled")=96,p("Enabled")=1,p("MatchRoles")=":%DB_USER"
    if ##class(Security.Applications).Exists(name) {
        set status=##class(Security.Applications).Modify(name,.p)
    } else {
        set status=##class(Security.Applications).Create(name,.p)
    }
    if $system.Status.IsError(status) { throw ##class(%Exception.StatusException).CreateFromStatus(status) }
    // Keep management separate from the anonymous demo application and require native session authentication for management operations.
    kill p
    set name="/med-audit-admin",p("NameSpace")="USER",p("DispatchClass")="HD.AdminREST",p("AutheEnabled")=96,p("Enabled")=1,p("MatchRoles")=":%DB_USER"
    if ##class(Security.Applications).Exists(name) { set status=##class(Security.Applications).Modify(name,.p) } else { set status=##class(Security.Applications).Create(name,.p) }
    if $system.Status.IsError(status) { throw ##class(%Exception.StatusException).CreateFromStatus(status) }
    set $namespace="USER"
    set status=##class(Ens.Director).RecoverProduction()
    if $system.Status.IsError(status) { throw ##class(%Exception.StatusException).CreateFromStatus(status) }
    if '##class(Ens.Director).IsProductionRunning() {
        set status=##class(Ens.Director).StartProduction("HD.Production")
        if $system.Status.IsError(status) { throw ##class(%Exception.StatusException).CreateFromStatus(status) }
    } else {
        // An old data volume may auto-start an old config; update the running Production after compilation.
        set status=##class(Ens.Director).UpdateProduction()
        if $system.Status.IsError(status) { throw ##class(%Exception.StatusException).CreateFromStatus(status) }
    }
    set status=##class(Ens.Director).SetAutoStart("HD.Production")
    if $system.Status.IsError(status) { throw ##class(%Exception.StatusException).CreateFromStatus(status) }
    write "HD_DEMO_SETUP_OK",!
}
}
