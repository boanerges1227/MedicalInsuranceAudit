Include %occStatus
Class HD.PackageSetup Extends %RegisteredObject
{
/// Record the ZPM install resource directory without modifying the existing Production or accounts.
ClassMethod Configure(root As %String) As %Status
{
    set ^HDConfig("packageRoot")=root
    quit $$$OK
}

/// Return the install resource directory; source mode keeps the original path.
ClassMethod Root() As %String
{
    quit $get(^HDConfig("packageRoot"),"/workspace/")
}

/// Initialize synthetic samples and the app in a dedicated USER instance; the caller must provide admin privileges.
ClassMethod Start() As %Status
{
    if $namespace'="USER" { quit $$$ERROR($$$GeneralError,"USER_NAMESPACE_REQUIRED") }
    set result=$$$OK
    try {
        do ##class(HD.NationalVector).Install()
        do ##class(HD.NationalVector).Import(..Root()_"samples/demo-policy-vectors.jsonl")
        do ##class(HD.Setup).Install()
        // Initialize the demo reviewer role so the default admin can process tasks.
        do ##class(HD.Workflow).EnsureRole()
    } catch ex { set result=ex.AsStatus() }
    quit result
}
}
