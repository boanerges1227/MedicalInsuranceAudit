Class HD.PEX.Setup Extends %RegisteredObject
{
/// Register the real Python PEX operation before starting Production; installation does not load the embedding model.
ClassMethod Install()
{
    set root=##class(HD.PackageSetup).Root()
    if '##class(%File).Exists(root_"tools/medaudit_pex.py") { throw ##class(%Exception.General).%New("PEX_RESOURCES_MISSING") }
    set sc=##class(EnsLib.PEX.Utils).RegisterComponent("medaudit_pex.EmbeddingOperation","%Python Server",root_"tools/medaudit_pex.py",1,"HD.PEX.EmbeddingOperation")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PEX_REGISTRATION_FAILED") }
    write "HD_PEX_REGISTERED",!
}
}
