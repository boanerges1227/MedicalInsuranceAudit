Class HD.Trace.Event Extends Ens.Request
{
/// Persist only typed, bounded telemetry; arbitrary prompts, headers, results, and exceptions have no field.
Property TraceId As %String(MAXLEN = 64);
Property RunId As %Integer;
Property EventId As %String(MAXLEN = 128);
Property CaseVersion As %Integer;
Property NativeParentMessageId As %BigInt;
Property NativeSessionId As %String(MAXLEN = 64);
Property SdkInvocationId As %String(MAXLEN = 80);
Property PromptVersion As %String(MAXLEN = 32);
Property Kind As %String(MAXLEN = 32);
Property SpanId As %String(MAXLEN = 64);
Property ParentSpanId As %String(MAXLEN = 64);
Property Sequence As %Integer;
Property AttemptSequence As %Integer;
Property StartedAt As %String(MAXLEN = 40);
Property EndedAt As %String(MAXLEN = 40);
Property DurationMs As %Numeric;
Property HttpStatus As %Integer;
Property Provider As %String(MAXLEN = 24);
Property Model As %String(MAXLEN = 128);
Property InputTokens As %Integer;
Property OutputTokens As %Integer;
Property UsageKnown As %Boolean [ InitialExpression = 0 ];
Property CostKnown As %Boolean [ InitialExpression = 0 ];
Property ToolCallCount As %Integer;
Property ToolName As %String(MAXLEN = 64);
Property Status As %String(MAXLEN = 24);
Property ErrorCode As %String(MAXLEN = 40);
Property RetryOf As %String(MAXLEN = 64);
Property RetryKind As %String(MAXLEN = 32);
Property Fallback As %String(MAXLEN = 16);
Property Coverage As %String(MAXLEN = 32);

/// Reject unsupported metadata at the native message boundary before any message is sent.
Method Validate()
{
    if '$listfind($listfromstring("run.start,run.end,sdk.start,sdk.end,model.request,model.response,tool.execution,tool.denial"),..Kind) { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if '$listfind($listfromstring("RUNNING,SUCCEEDED,FAILED,DENIED,UNKNOWN"),..Status) { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if '$listfind($listfromstring("pending,http-attempts,sdk-invocation-only"),..Coverage) { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if (..ToolName'="")&&(..ToolName'="get_case_evidence")&&(..ToolName'="get_policy_evidence")&&(..ToolName'="unregistered") { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if (..ErrorCode'="")&&('($listfind($listfromstring("UPSTREAM_HTTP_ERROR,UPSTREAM_IO_ERROR,UPSTREAM_TIMEOUT,UPSTREAM_NETWORK_ERROR,UPSTREAM_REDIRECT,UPSTREAM_STREAMING_UNSUPPORTED,UPSTREAM_RESPONSE_TOO_LARGE,TOOL_FAILED,TOOL_DENIED,SDK_FAILED,RUN_FAILED,TRACE_FAILED"),..ErrorCode))) { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if (..RetryKind'="")&&(..RetryKind'="none")&&(..RetryKind'="sdk-observed")&&(..RetryKind'="observed")&&(..RetryKind'="identical-after-failure") { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if (..Provider'="")&&('$listfind($listfromstring("openai,anthropic,nim,gemini,google"),..Provider)) { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if ..Fallback'="none" { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if (..RunId<0)!(..CaseVersion<0)!(..Sequence<1)!(..DurationMs<0)!(..InputTokens<0)!(..OutputTokens<0)!(..ToolCallCount<0) { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    if ..PromptVersion'="hd-agent-v1" { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
    for field="TraceId","EventId","NativeSessionId","SdkInvocationId","SpanId","ParentSpanId","Model","RetryOf","StartedAt","EndedAt" {
        set value=$property($this,field)
        if $length(value)>128 { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") }
        for i=1:1:$length(value) { set char=$extract(value,i),ascii=$ascii(char) if '((ascii>47)&&(ascii<58)) ,'((ascii>64)&&(ascii<91)),'((ascii>96)&&(ascii<123)),'("._:/-"[char) { throw ##class(%Exception.General).%New("TRACE_METADATA_INVALID") } }
    }
}
}
