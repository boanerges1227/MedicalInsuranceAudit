"""Text-vectorization entry with a pinned model, called by IRIS Embedded Python."""
import gc
import json
from pathlib import Path

import national_embed

MODEL_DIR = Path('/durable/iris/private/upload-model')
MAX_BATCH = 8
MAX_TEXT_CHARS = 4096


def _load_model():
    """Verify the model and create a temporary session on each call."""
    old_model = national_embed.MODEL
    national_embed.MODEL = MODEL_DIR
    try:
        return national_embed.create_session()
    except Exception as exc:
        # Model and dependency errors are service unavailability, not user input errors.
        raise RuntimeError('MODEL_NOT_READY') from exc
    finally:
        national_embed.MODEL = old_model


def encode_json(texts_json, query=False):
    """Validate the batch and call the same embedding model, returning traceable vectors and model version."""
    texts = json.loads(texts_json)
    if not isinstance(texts, list) or not 1 <= len(texts) <= MAX_BATCH:
        raise ValueError('INVALID_BATCH')
    if any(not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT_CHARS for text in texts):
        raise ValueError('INVALID_TEXT')
    session, tokenizer = _load_model()
    try:
        vectors = national_embed.embed_batch(session, tokenizer, texts, query=bool(query))
        return json.dumps({'dimensions': 512, 'model_hash': national_embed.MODEL_HASH, 'vectors': vectors.tolist()}, ensure_ascii=False, allow_nan=False)
    finally:
        # Release the ONNX session promptly; the underlying allocator may still retain some memory pages.
        del session, tokenizer
        gc.collect()
