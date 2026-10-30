Class HD.AgentMonitor Extends %RegisteredObject
{
/// Summarize registered tasks only; missing token counts or durations do not mean zero usage.
ClassMethod Summary() As %DynamicObject
{
    set id="",total=0,started=0,finished=0,failed=0,usageCount=0,durationCount=0,input=0,output=0,duration=0
    for {
        set id=$order(^HDData("agentRuns",id)) quit:id=""
        set raw=$get(^HDData("agentRuns",id)) if raw="" { continue }
        set job={}.%FromJSON(raw),total=total+1,status=job.%Get("status","")
        if status="SUCCEEDED" { set finished=finished+1 }
        if status="FAILED" { set failed=failed+1 }
        set result=job.%Get("result",{})
        if '$isobject(result) { continue }
        if result.%Get("modelStarted",0) { set started=started+1 }
        set usage=result.%Get("usage",{})
        if $isobject(usage),usage.%GetTypeOf("total_prompt_tokens")="number",usage.%GetTypeOf("total_completion_tokens")="number" {
            set usageCount=usageCount+1,input=input+usage.%Get("total_prompt_tokens"),output=output+usage.%Get("total_completion_tokens")
        }
        if result.%GetTypeOf("elapsedSeconds")="number" { set durationCount=durationCount+1,duration=duration+result.%Get("elapsedSeconds") }
    }
    set data={"scope":"recorded_agent_runs","total":(total),"modelStarted":(started),"succeeded":(finished),"failed":(failed),"usageRecorded":(usageCount),"durationRecorded":(durationCount)}
    if usageCount { set data.inputTokens=input,data.outputTokens=output } else { set data.inputTokens="",data.outputTokens="" }
    if durationCount { set data.averageSeconds=duration/durationCount } else { set data.averageSeconds="" }
    quit data
}
}
