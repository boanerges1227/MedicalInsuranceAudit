package medaudit.pex;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Reproduce the pinned case-sensitive Chinese BERT tokenizer without truncating evidence. */
public final class BertTokenizer {
    private final Map<String, Integer> vocabulary = new HashMap<>();
    private static final Pattern SPECIAL = Pattern.compile("\\[PAD\\]|\\[UNK\\]|\\[CLS\\]|\\[SEP\\]|\\[MASK\\]");

    /** Load only the exact configuration whose SHA-256 is verified by the embedding engine. */
    public BertTokenizer(Path path) throws Exception {
        JsonNode root = new ObjectMapper().readTree(path.toFile());
        JsonNode config = root.path("normalizer");
        if (!"BertNormalizer".equals(config.path("type").asText()) || config.path("lowercase").asBoolean()
                || !config.path("clean_text").asBoolean() || !config.path("handle_chinese_chars").asBoolean()
                || !"WordPiece".equals(root.path("model").path("type").asText())) {
            throw new IllegalStateException("TOKENIZER_CONFIG_UNSUPPORTED");
        }
        root.path("model").path("vocab").fields().forEachRemaining(e -> vocabulary.put(e.getKey(), e.getValue().asInt()));
    }

    /** Preserve registered special tokens, then add the same CLS/SEP template used by the Python tokenizer. */
    public long[] encode(String text) {
        List<Long> ids = new ArrayList<>(); ids.add(101L);
        Matcher matcher = SPECIAL.matcher(text); int cursor = 0;
        while (matcher.find()) {
            appendText(text.substring(cursor, matcher.start()), ids);
            ids.add(vocabulary.get(matcher.group()).longValue()); cursor = matcher.end();
        }
        appendText(text.substring(cursor), ids); ids.add(102L);
        if (ids.size() > 512) throw new IllegalArgumentException("TOKEN_LIMIT");
        long[] result = new long[ids.size()]; for (int i = 0; i < result.length; i++) result[i] = ids.get(i);
        return result;
    }

    /** Apply clean-text, Chinese-character separation and BERT punctuation splitting in Unicode code points. */
    private void appendText(String input, List<Long> ids) {
        StringBuilder token = new StringBuilder();
        input.codePoints().forEach(cp -> {
            if (PinnedUnicode.isDropped(cp)) return;
            if (PinnedUnicode.isSpace(cp)) { appendWord(token, ids); return; }
            if (PinnedUnicode.isChinese(cp) || PinnedUnicode.isPunctuation(cp)) {
                appendWord(token, ids); token.appendCodePoint(cp); appendWord(token, ids);
            } else token.appendCodePoint(cp);
        });
        appendWord(token, ids);
    }

    /** Greedily choose the longest WordPiece; a missing piece replaces the entire word with UNK. */
    private void appendWord(StringBuilder buffer, List<Long> ids) {
        if (buffer.length() == 0) return;
        int[] points = buffer.toString().codePoints().toArray(); buffer.setLength(0);
        if (points.length > 100) { ids.add(100L); return; }
        List<Long> pieces = new ArrayList<>(); int start = 0;
        while (start < points.length) {
            Integer found = null; int end = points.length;
            for (; end > start; end--) {
                String word = (start == 0 ? "" : "##") + new String(points, start, end - start);
                found = vocabulary.get(word); if (found != null) break;
            }
            if (found == null) { ids.add(100L); return; }
            pieces.add(found.longValue()); start = end;
        }
        ids.addAll(pieces);
    }

}
