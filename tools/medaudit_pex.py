"""Native Python PEX business operation for medical-audit query vectorization."""
import json
import iris.pex

from pex_embedding_core import encode


class EmbeddingOperation(iris.pex.BusinessOperation):
    """Resolve a short-lived request ID and run the pinned encoder through the external language server."""

    def OnMessage(self, request):
        """Keep query text out of persisted Production messages and suppress private exception details."""
        result = {"status": "FAILED", "code": "EMBEDDING_UNAVAILABLE"}
        try:
            data = json.loads(request._iris.classMethodValue("HD.EmbeddedVector", "ReadPEXInput", request.get("Payload")))
            if data.get("status") == "OK":
                result = encode(data.get("text"), data.get("query", False))
            else:
                result = {"status": "FAILED", "code": "INVALID_INPUT"}
        except Exception:
            pass
        response = request._iris.classMethodObject("HD.Reply", "%New")
        response.set("Payload", json.dumps(result, separators=(",", ":"), allow_nan=False))
        return response
