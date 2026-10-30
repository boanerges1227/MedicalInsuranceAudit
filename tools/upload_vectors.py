#!/usr/bin/env python3
"""Process the local IRIS upload queue and generate document vectors with the pinned Chinese model."""
import base64
import hashlib
import fcntl
import io
import json
import os
import subprocess
import sys
import time
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

from national_embed import create_session, embed_batch, MODEL_HASH

BASE = Path(__file__).resolve().parents[1]
TEMP = Path(os.environ.get('MED_AUDIT_UPLOAD_TEMP', str(BASE / 'src' / 'upload-private')))
MAX_BYTES = 2 * 1024 * 1024


def extract_text(filename, content):
    """Extract supported text formats and limit DOCX expansion to reject oversized archives."""
    suffix = Path(filename).suffix.lower()
    if len(content) > MAX_BYTES or not content:
        raise ValueError('文件为空或超过 2 MB')
    if suffix in ('.txt', '.md'):
        try:
            return content.decode('utf-8-sig')
        except UnicodeDecodeError as exc:
            raise ValueError('文本必须使用 UTF-8 编码') from exc
    if suffix != '.docx':
        raise ValueError('仅支持 TXT、Markdown 和 DOCX 文件')
    try:
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            info = archive.getinfo('word/document.xml')
            if info.file_size > 10 * MAX_BYTES:
                raise ValueError('DOCX 解压后内容过大')
            root = ET.fromstring(archive.read(info))
        ns = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
        return '\n'.join(''.join(n.text or '' for n in p.iter(ns + 't')) for p in root.iter(ns + 'p'))
    except (zipfile.BadZipFile, KeyError, ET.ParseError) as exc:
        raise ValueError('DOCX 文件无效') from exc


def split_text(text, tokenizer, limit=512):
    """Split text in source order and validate each chunk against the model's actual token limit."""
    chunks = []
    while text:
        end = min(len(text), 300)
        while end and len(tokenizer.encode(text[:end]).ids) > limit:
            end //= 2
        if not end:
            raise ValueError('无法在模型长度限制内分段')
        chunks.append(text[:end])
        text = text[end:]
    return chunks


def iris(command, timeout=60):
    """Call this project's IRIS session using fixed commands and server-generated numeric task IDs only."""
    # Connect directly to local IRIS in the container; retain Compose sessions for host execution.
    cmd = ['iris', 'session', 'IRIS', '-U', 'USER'] if os.environ.get('MED_AUDIT_WORKER_IN_IRIS') == '1' else ['docker', 'compose', 'exec', '-T', 'iris', 'iris', 'session', 'IRIS', '-U', 'USER']
    result = subprocess.run(cmd, cwd=BASE, input=command + '\nhalt\n', text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('IRIS 会话不可用')
    return result.stdout


def process(meta, parts, session, tokenizer):
    """Parse documents and generate vectors in batches, then import them atomically through an IRIS transaction."""
    data = base64.b64decode(''.join(parts), validate=True)
    if len(data) != meta['size'] or len(data) > MAX_BYTES:
        raise ValueError('上传文件长度不一致')
    text = extract_text(meta['filename'], data)
    if not text.strip():
        raise ValueError('文件没有可提取的正文')
    chunks = split_text(text, tokenizer)
    if len(chunks) > 10000:
        raise ValueError('文档片段数量超过限制')
    TEMP.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = TEMP / (str(meta['id']) + '.jsonl')
    try:
        with path.open('w', encoding='utf-8') as out:
            for i in range(0, len(chunks), 8):
                batch = chunks[i:i + 8]
                vectors = embed_batch(session, tokenizer, batch)
                for j, (chunk, vector) in enumerate(zip(batch, vectors)):
                    row = {'index': i + j, 'text': chunk, 'text_sha256': hashlib.sha256(chunk.encode()).hexdigest(), 'model_sha256': MODEL_HASH, 'vector_csv': ','.join(format(float(x), '.9g') for x in vector)}
                    out.write(json.dumps(row, ensure_ascii=False) + '\n')
        container_mode = '1' if os.environ.get('MED_AUDIT_WORKER_IN_IRIS') == '1' else '0'
        output = iris('try { do ##class(HD.UploadVector).Import(' + str(meta['id']) + ',' + container_mode + ') } catch ex { write "UPLOAD_ERROR=",ex.Name,! }', 300)
        if 'UPLOAD_IMPORTED=' not in output:
            raise RuntimeError('IRIS 向量写入失败')
    finally:
        path.unlink(missing_ok=True)


def main():
    """Continuously claim queued tasks and mark tasks failed on model or database errors."""
    state_dir = Path(os.environ.get('MED_AUDIT_WORKER_STATE', str(BASE / 'artifacts' / 'upload-worker')))
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_file = (state_dir / 'worker.lock').open('w')
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    session = tokenizer = None
    recovered = False
    while True:
        try:
            # Recover interrupted tasks before claiming new work when IRIS becomes available again.
            if not recovered:
                iris('do ##class(HD.UploadVector).Recover()')
                recovered = True
            result = iris('do ##class(HD.UploadVector).Claim()')
            lines = result.splitlines()
            raw = next((line.split('UPLOAD_META=', 1)[1] for line in lines if 'UPLOAD_META=' in line), None)
            if raw:
                meta = json.loads(raw)
                parts = [line.split('UPLOAD_PART=', 1)[1] for line in lines if 'UPLOAD_PART=' in line]
                try:
                    if session is None:
                        session, tokenizer = create_session()
                    process(meta, parts, session, tokenizer)
                except Exception as exc:
                    # Keep source text and keys out of error messages to prevent sensitive data from entering logs.
                    print('上传任务失败:', type(exc).__name__, flush=True)
                    code = 'INVALID_DOCUMENT' if isinstance(exc, ValueError) else 'PROCESSING_FAILED'
                    iris('do ##class(HD.UploadVector).Fail(' + str(int(meta['id'])) + ',"' + code + '")')
        except Exception as exc:
            print('向量工作进程等待 IRIS:', type(exc).__name__, flush=True)
        time.sleep(3)


if __name__ == '__main__':
    main()
