package medaudit.pex;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.intersystems.enslib.pex.BusinessOperation;
import com.intersystems.jdbc.IRISObject;
import java.nio.file.Path;

/** Java PEX operation whose persisted request contains only an expiring random identifier. */
public final class EmbeddingOperation extends BusinessOperation {
    private final ObjectMapper json = new ObjectMapper();
    private final EmbeddingEngine engine = new EmbeddingEngine(Path.of("/durable/iris/private/upload-model"));

    /** Registration/startup stays available even before the administrator provisions the local model. */
    @Override public void OnInit() {}

    /** Per-request native ONNX resources are closed by the engine, so teardown has no model state. */
    @Override public void OnTearDown() {}

    /** Resolve private input over the native callback and return a native HD.Reply, suppressing diagnostics. */
    @Override public Object OnMessage(Object incoming) throws Exception {
        if (!(incoming instanceof IRISObject)) throw new IllegalArgumentException("NATIVE_REQUEST_REQUIRED");
        IRISObject request = (IRISObject) incoming;
        ObjectNode result = EmbeddingEngine.failure("EMBEDDING_UNAVAILABLE");
        try {
            String id = request.getString("Payload");
            String raw = request.iris.classMethodString("HD.EmbeddedVector", "ReadPEXInput", id);
            JsonNode data = json.readTree(raw);
            result = "OK".equals(data.path("status").asText()) ? engine.encode(data) : EmbeddingEngine.failure("INVALID_INPUT");
        } catch (Exception | LinkageError unavailable) { /* Keep source text and infrastructure errors out of responses. */ }
        IRISObject response = (IRISObject) request.iris.classMethodObject("HD.Reply", "%New");
        response.set("Payload", json.writeValueAsString(result)); return response;
    }
}
