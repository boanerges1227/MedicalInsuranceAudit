Include %occStatus
Class HD.PackagePreflight Extends %RegisteredObject
{
/// Create the vector table before static SQL is compiled; preserve existing data on reinstall.
ClassMethod InstallSchema() As %Status
{
    set result=$$$OK
    try {
        set sql="SELECT COUNT(*) AS total FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?"
        set st=##class(%SQL.Statement).%New(),sc=st.%Prepare(sql)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        set rs=st.%Execute("HD","NationalVectors")
        if 'rs.%Next() { throw ##class(%Exception.General).%New("SCHEMA_CHECK_FAILED") }
        if rs.%Get("total")=0 {
            set sql="CREATE TABLE HD.NationalVectors (ChunkId VARCHAR(512) NOT NULL, TextHash VARCHAR(64) NOT NULL, ModelHash VARCHAR(64) NOT NULL, SourcePath VARCHAR(512) NOT NULL, ChunkText VARCHAR(4000), Metadata VARCHAR(16000), Embedding VECTOR(FLOAT,512), PRIMARY KEY (ChunkId))"
            set rs=##class(%SQL.Statement).%ExecDirect(,sql)
            if rs.%SQLCODE<0 { throw ##class(%Exception.General).%New("CREATE_TABLE_FAILED") }
        }
    } catch ex { set result=ex.AsStatus() }
    quit result
}
}
