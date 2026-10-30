Class HD.Request Extends Ens.Request
{
/// Store the JSON request payload so IRIS Production can record the message flow.
Property Payload As %String(MAXLEN = "");

/// File intake source identifier, used only to link file-level processing records.
Property FileName As %String(MAXLEN = 255);
}
