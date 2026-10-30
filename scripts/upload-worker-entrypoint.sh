#!/usr/bin/env bash
set -euo pipefail
# Prepare worker dependencies and models independently; failures do not change core service health.
export MED_AUDIT_WORKER_IN_IRIS=1
export MED_AUDIT_MODEL_DIR=/durable/iris/private/upload-model
export MED_AUDIT_UPLOAD_TEMP=/durable/iris/private/upload-private
export MED_AUDIT_WORKER_STATE=/durable/iris/private/upload-worker
runtime=/durable/iris/private/upload-python
mkdir -p "$MED_AUDIT_WORKER_STATE" "$MED_AUDIT_UPLOAD_TEMP"
while true; do
  if [[ ! -x "$runtime/bin/python" ]]; then python3 -m venv "$runtime" || { echo 'UPLOAD_SETUP_VENV_FAILED'; sleep 30; continue; }; fi
  if ! "$runtime/bin/python" -c 'import numpy, onnxruntime, tokenizers' >/dev/null 2>&1; then
    echo 'UPLOAD_SETUP_INSTALLING_DEPENDENCIES'
    "$runtime/bin/python" -m pip install -r /workspace/requirements.txt || { echo 'UPLOAD_SETUP_DEPENDENCIES_FAILED'; sleep 30; continue; }
  fi
  if ! "$runtime/bin/python" /workspace/scripts/download-upload-model.py; then
    echo 'UPLOAD_SETUP_MODEL_FAILED; retrying in 30 seconds'
    sleep 30
    continue
  fi
  echo 'UPLOAD_WORKER_STARTING'
  exec "$runtime/bin/python" /workspace/tools/upload_vectors.py
 done
