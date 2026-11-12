Class HD.Trace.RelayBridge Extends %RegisteredObject
{
/// Keep relay objects in this process's Python RAM; only opaque handles cross into ObjectScript.
ClassMethod Start(root As %String, upstream As %String) As %String [ Language = python ]
{
    import importlib.util, sys, uuid
    name = "hd_trace_relay"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, root + "tools/trace_relay.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
        module._hd_registry = {}
    module = sys.modules[name]
    relay = module.Relay(upstream, timeout=110)
    handle = uuid.uuid4().hex
    module._hd_registry[handle] = relay
    return handle
}

/// Return only the ephemeral loopback address; do not persist original endpoint or credentials.
ClassMethod URL(handle As %String) As %String [ Language = python ]
{
    import sys
    return sys.modules["hd_trace_relay"]._hd_registry[handle].base_url
}

/// Transfer the observer's sanitized metadata on the IRIS worker thread, never from an HTTP thread.
ClassMethod Drain(handle As %String) As %String [ Language = python ]
{
    import json, sys
    return json.dumps(sys.modules["hd_trace_relay"]._hd_registry[handle].drain(), separators=(",", ":"))
}

/// Always stop the observer and discard all in-memory request state, including after model errors.
ClassMethod Stop(handle As %String) [ Language = python ]
{
    import sys
    module = sys.modules.get("hd_trace_relay")
    if module:
        relay = module._hd_registry.pop(handle, None)
        if relay:
            relay.close()
}
}
