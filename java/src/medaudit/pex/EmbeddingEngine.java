package medaudit.pex;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.LinkedHashMap;
import java.util.Map;

/** Run the pinned 512-dimensional encoder in Java; no Python inference or silent fallback is used. */
public final class EmbeddingEngine {
    public static final String MODEL_HASH = "e256a606233996478f0eb6c99c9814e3797043d4a5563b4646b10929546196e5";
    public static final String TOKEN_HASH = "48cea5d44424912a6fd1ea647bf4fe50b55ab8b1e5879c3275f80e339e8fae26";
    public static final String QUERY_PREFIX = "为这个句子生成表示以用于检索相关文章：";
    private static final ObjectMapper JSON = new ObjectMapper();
    private final Path modelDirectory;

    /** Select the private durable model directory, never a query-supplied path. */
    public EmbeddingEngine(Path directory) { modelDirectory = directory; }

    /** Enforce input, model hashes, token ceiling, CLS pooling and finite normalized-vector output. */
    public ObjectNode encode(JsonNode data) {
        JsonNode textNode = data.get("text");
        if (textNode == null || !textNode.isTextual()) return failure("INVALID_INPUT");
        String text = textNode.asText();
        if (text.codePointCount(0, text.length()) > 4096 || text.isEmpty()
                || text.codePoints().allMatch(PinnedUnicode::isInputSpace)) return failure("INVALID_INPUT");
        try {
            Path model = modelDirectory.resolve("model.onnx"), tokenizerPath = modelDirectory.resolve("tokenizer.json");
            if (!MODEL_HASH.equals(sha256(model)) || !TOKEN_HASH.equals(sha256(tokenizerPath))) return failure("EMBEDDING_UNAVAILABLE");
            BertTokenizer tokenizer = new BertTokenizer(tokenizerPath);
            boolean query = data.path("query").asBoolean(false) || data.path("query").asInt(0) != 0;
            long[] ids;
            try { ids = tokenizer.encode((query ? QUERY_PREFIX : "") + text); }
            catch (IllegalArgumentException invalid) { return failure("INVALID_INPUT"); }
            long[][] tokenIds = { ids }, attention = { new long[ids.length] }, types = { new long[ids.length] };
            java.util.Arrays.fill(attention[0], 1L);
            OrtEnvironment environment = OrtEnvironment.getEnvironment();
            // Limit inference to the existing CPU thread budget and release every native tensor/session promptly.
            try (OrtSession.SessionOptions options = new OrtSession.SessionOptions()) {
                options.setIntraOpNumThreads(4); options.setInterOpNumThreads(1);
                try (OrtSession session = environment.createSession(model.toString(), options);
                     OnnxTensor input = OnnxTensor.createTensor(environment, tokenIds);
                     OnnxTensor mask = OnnxTensor.createTensor(environment, attention);
                     OnnxTensor typeIds = OnnxTensor.createTensor(environment, types)) {
                    Map<String, OnnxTensor> inputs = new LinkedHashMap<>();
                    inputs.put("input_ids", input); inputs.put("attention_mask", mask); inputs.put("token_type_ids", typeIds);
                    try (OrtSession.Result result = session.run(inputs)) {
                        float[][][] hidden = (float[][][]) result.get(0).getValue();
                        if (hidden.length != 1 || hidden[0].length != ids.length) return failure("EMBEDDING_UNAVAILABLE");
                        return normalize(hidden[0][0]);
                    }
                }
            }
        } catch (Exception | LinkageError unavailable) { return failure("EMBEDDING_UNAVAILABLE"); }
    }

    /** Validate and L2-normalize CLS values before producing the existing SQL TO_VECTOR CSV contract. */
    public static ObjectNode normalize(float[] values) {
        if (values == null || values.length != 512) return failure("EMBEDDING_UNAVAILABLE");
        double squared = 0;
        for (float value : values) { if (!Float.isFinite(value)) return failure("EMBEDDING_UNAVAILABLE"); squared += (double) value * value; }
        float norm = (float) Math.sqrt(squared);
        if (!Float.isFinite(norm) || norm <= 0) return failure("EMBEDDING_UNAVAILABLE");
        StringBuilder csv = new StringBuilder();
        for (float value : values) { if (csv.length() != 0) csv.append(','); csv.append(Float.toString(value / norm)); }
        ObjectNode result = JSON.createObjectNode(); result.put("status", "OK"); result.put("dimensions", 512);
        result.put("model_hash", MODEL_HASH); result.put("vector_csv", csv.toString()); return result;
    }

    /** Return bounded public failure codes without private paths, source text or exception messages. */
    public static ObjectNode failure(String code) {
        ObjectNode result = JSON.createObjectNode(); result.put("status", "FAILED"); result.put("code", code); return result;
    }

    /** Stream hashes rather than keeping the model file in Java heap memory. */
    public static String sha256(Path path) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        try (InputStream stream = Files.newInputStream(path)) {
            byte[] block = new byte[1048576]; int count;
            while ((count = stream.read(block)) != -1) hash.update(block, 0, count);
        }
        StringBuilder result = new StringBuilder(); for (byte b : hash.digest()) result.append(String.format("%02x", b & 255));
        return result.toString();
    }
}
