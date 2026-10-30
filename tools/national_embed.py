#!/usr/bin/env python3
"""Pinned local Chinese embedding model helpers shared by the upload worker and embedded vector search."""
import hashlib,os
from pathlib import Path
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer
BASE=Path(__file__).resolve().parents[1];MODEL=Path(os.environ.get('MED_AUDIT_MODEL_DIR',str(BASE/'artifacts/national-embedding-model')))
MODEL_HASH='e256a606233996478f0eb6c99c9814e3797043d4a5563b4646b10929546196e5'
TOKEN_HASH='48cea5d44424912a6fd1ea647bf4fe50b55ab8b1e5879c3275f80e339e8fae26'

def sha(path):
    """Compute SHA-256 hashes to pin model and input versions."""
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''):h.update(block)
    return h.hexdigest()

def validate_vectors(values,count,dimension=512):
    """Reject incorrect dimensions, nonfinite values, and zero vectors; apply L2 normalization for similarity search."""
    values=np.asarray(values,dtype=np.float32)
    if values.shape!=(count,dimension) or not np.isfinite(values).all():raise ValueError('向量维度或数值无效')
    norms=np.linalg.norm(values,axis=1,keepdims=True)
    if np.any(norms<=0):raise ValueError('零向量')
    return values/norms

def create_session():
    """Verify local model hashes and create a CPU inference session."""
    if sha(MODEL/'model.onnx')!=MODEL_HASH or sha(MODEL/'tokenizer.json')!=TOKEN_HASH:raise ValueError('模型或分词器哈希不匹配')
    opt=ort.SessionOptions();opt.intra_op_num_threads=4;opt.inter_op_num_threads=1
    return ort.InferenceSession(str(MODEL/'model.onnx'),sess_options=opt,providers=['CPUExecutionProvider']),Tokenizer.from_file(str(MODEL/'tokenizer.json'))

def embed_batch(session,tokenizer,texts,query=False):
    """Encode batches with CLS pooling and normalization; reject oversized inputs without truncation."""
    if query:texts=['为这个句子生成表示以用于检索相关文章：'+x for x in texts]
    enc=[tokenizer.encode(x) for x in texts]
    if any(len(e.ids)>512 for e in enc):raise ValueError('文本超过模型512 token上限')
    n=max(len(e.ids) for e in enc);inputs={name:np.zeros((len(enc),n),dtype=np.int64) for name in ('input_ids','attention_mask','token_type_ids')}
    for i,e in enumerate(enc):
        inputs['input_ids'][i,:len(e.ids)]=e.ids;inputs['attention_mask'][i,:len(e.ids)]=e.attention_mask;inputs['token_type_ids'][i,:len(e.ids)]=e.type_ids
    return validate_vectors(session.run(None,inputs)[0][:,0,:],len(texts))
