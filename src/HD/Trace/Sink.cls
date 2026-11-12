Class HD.Trace.Sink Extends Ens.BusinessOperation
{
/// Accept the strict native telemetry schema; the Production header supplies session and parent linkage.
Method OnMessage(request As HD.Trace.Event, Output response As HD.Trace.Ack) As %Status
{
    do request.Validate()
    set response=##class(HD.Trace.Ack).%New(),response.Accepted=1
    quit 1
}
}
