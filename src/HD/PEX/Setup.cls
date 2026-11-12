Class HD.PEX.Setup Extends %RegisteredObject
{
/// Store compiled classes and the verified ONNX Java dependency outside the source checkout.
ClassMethod RuntimeRoot() As %String
{
    quit $system.Util.ManagerDirectory()_"medaudit-java-pex/"
}

/// Build and register a real Java PEX operation without loading models or changing business data.
ClassMethod Install()
{
    set root=##class(HD.PackageSetup).Root(),target=..RuntimeRoot()
    if '##class(%File).Exists(root_"java/build.sh") { throw ##class(%Exception.General).%New("PEX_RESOURCES_MISSING") }
    set exit=$ZF(-100,"","/bin/bash",root_"java/build.sh",target,$system.Util.InstallDirectory())
    if exit'=0 { throw ##class(%Exception.General).%New("PEX_JAVA_BUILD_FAILED") }
    set sdk=$system.Util.InstallDirectory()_"dev/java/lib/1.8/intersystems-pex-1.0.0-shaded.jar"
    set classpath=sdk_":"_target_"medaudit-pex.jar:"_target_"onnxruntime-1.20.0.jar"
    set sc=##class(EnsLib.PEX.Utils).RegisterComponent("medaudit.pex.EmbeddingOperation","%Java Server",classpath,1,"HD.PEX.EmbeddingOperation")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PEX_REGISTRATION_FAILED") }
    write "HD_JAVA_PEX_REGISTERED",!
}
}
