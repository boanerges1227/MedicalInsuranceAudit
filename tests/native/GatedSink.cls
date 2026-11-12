Class HD.Trace.GatedSink Extends HD.Trace.Sink
{
/// Hold or reject only the synthetic test's final acknowledgement; production uses the unmodified strict Sink.
Method OnMessage(request As HD.Trace.Event, Output response As HD.Trace.Ack) As %Status
{
    if request.Kind="run.end",$data(^HDTraceTest("gate",request.EventId)) {
        set ^HDTraceTest("arrived",request.EventId)=1,begin=$zh
        for { quit:$get(^HDTraceTest("release",request.EventId))  quit:($zh-begin)>8  hang .02 }
        do request.Validate()
        set response=##class(HD.Trace.Ack).%New(),response.Accepted=+$get(^HDTraceTest("accept",request.EventId),1)
        quit 1
    }
    quit ##super(request,.response)
}
}
