package medaudit.pex;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Path;

/** Small local acceptance harness using the production tokenizer and engine without model API calls. */
public final class CoreCLI {
    /** Consume one JSON request on stdin and emit only structured test output. */
    public static void main(String[] args) throws Exception {
        ObjectMapper json = new ObjectMapper(); JsonNode input = json.readTree(System.in); Object result;
        Path model = Path.of(System.getenv().getOrDefault("MED_AUDIT_JAVA_MODEL_DIR", "/durable/iris/private/upload-model"));
        if (args[0].equals("tokens")) {
            BertTokenizer tokenizer = new BertTokenizer(model.resolve("tokenizer.json"));
            java.util.List<long[]> tokens = new java.util.ArrayList<>();
            for (JsonNode text : input.path("texts")) tokens.add(tokenizer.encode(text.asText()));
            result = tokens;
        }
        else if (args[0].equals("validate")) {
            JsonNode data = input.path("values"); float[] values = new float[data.size()];
            for (int i = 0; i < values.length; i++) values[i] = data.get(i).isNumber() ? (float) data.get(i).asDouble() : Float.NaN;
            result = EmbeddingEngine.normalize(values);
        } else result = new EmbeddingEngine(model).encode(input);
        System.out.println(json.writeValueAsString(result));
    }
}
