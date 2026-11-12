"""Run the pinned text encoder outside the IRIS process and validate its result."""
import json
import math
import site
import sys
from pathlib import Path


def format_result(data):
    """Return the existing 512-dimensional contract only for a finite, versioned single vector."""
    vectors = data.get("vectors", [])
    if data.get("dimensions") != 512 or not data.get("model_hash") or len(vectors) != 1:
        raise ValueError("INVALID_EMBEDDING_RESULT")
    values = vectors[0]
    if len(values) != 512 or any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in values):
        raise ValueError("INVALID_EMBEDDING_RESULT")
    return {"status": "OK", "dimensions": 512, "model_hash": data["model_hash"],
            "vector_csv": ",".join(format(float(value), ".9g") for value in values)}


def encode(text, query=False):
    """Use the same verified model helper while returning only stable, non-sensitive failures."""
    if not isinstance(text, str) or not text.strip() or len(text) > 4096:
        return {"status": "FAILED", "code": "INVALID_INPUT"}
    try:
        packages = Path("/durable/iris/private/upload-python/lib") / ("python%d.%d" % sys.version_info[:2]) / "site-packages"
        site.addsitedir(str(packages))
        # Native file-based PEX registration does not retain sibling modules on sys.path.
        tools_dir = str(Path(__file__).resolve().parent)
        if tools_dir not in sys.path:
            sys.path.insert(0, tools_dir)
        import embedded_vectors
    except Exception:
        return {"status": "FAILED", "code": "EMBEDDING_UNAVAILABLE"}
    try:
        raw = embedded_vectors.encode_json(json.dumps([text], ensure_ascii=False), query=bool(query))
    except (ValueError, TypeError):
        # Preserve the legacy caller contract, including tokenizer limits below the character ceiling.
        return {"status": "FAILED", "code": "INVALID_INPUT"}
    except Exception:
        return {"status": "FAILED", "code": "EMBEDDING_UNAVAILABLE"}
    try:
        # A malformed encoder response is a service failure, never an input validation refusal.
        return format_result(json.loads(raw))
    except Exception:
        return {"status": "FAILED", "code": "EMBEDDING_UNAVAILABLE"}
