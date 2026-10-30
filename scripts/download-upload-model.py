#!/usr/bin/env python3
"""Download pinned model files and verify their hashes before atomic replacement."""
import hashlib
import os
import pathlib
import urllib.parse
import urllib.request

REVISION = '365c58829c0d3b1df7df9382da63c48441bd0d66'
ROOT = pathlib.Path(os.environ['MED_AUDIT_MODEL_DIR'])
FILES = {
    'model.onnx': 'e256a606233996478f0eb6c99c9814e3797043d4a5563b4646b10929546196e5',
    'tokenizer.json': '48cea5d44424912a6fd1ea647bf4fe50b55ab8b1e5879c3275f80e339e8fae26',
}


def digest(path):
    """Hash files in chunks without loading the entire model into memory."""
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def main():
    """Reuse verified cached files; replace model files only after downloading and verifying them."""
    ROOT.mkdir(parents=True, exist_ok=True)
    for name, expected in FILES.items():
        target = ROOT / name
        if target.is_file() and digest(target) == expected:
            print('MODEL_CACHED:', name, flush=True)
            continue
        # The published ONNX filename differs from the local cache filename.
        remote_name = 'bge-small-zh-v1.5.onnx' if name == 'model.onnx' else name
        query = urllib.parse.urlencode({'Revision': REVISION, 'FilePath': remote_name})
        url = 'https://modelscope.cn/api/v1/models/lyf219/bge-small-zh-v1.5-onnx/repo?' + query
        tmp = target.with_suffix(target.suffix + '.tmp')
        try:
            print('MODEL_DOWNLOAD:', name, flush=True)
            with urllib.request.urlopen(url, timeout=120) as response, tmp.open('wb') as output:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
            if digest(tmp) != expected:
                raise ValueError('model digest mismatch: ' + name)
            tmp.replace(target)
        finally:
            tmp.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
