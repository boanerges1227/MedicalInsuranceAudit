#!/usr/bin/env bash
set -euo pipefail
# Compile only project classes; InterSystems libraries remain supplied by the installed IRIS instance.
source_dir="$(cd "$(dirname "$0")" && pwd)"
target="${1:?Usage: build.sh /writable/runtime/directory}"
mkdir -p "$target"
ort="$target/onnxruntime-1.20.0.jar"
expected=c46608681692b3693914defb42fa3119ad7cb6146870581ece247e0ed5793fe8
if [[ ! -f "$ort" ]]; then
  # The initial dependency fetch is HTTPS-only; offline deployments may preseed this exact verified JAR.
  python3 - "$ort.download" <<'FETCH'
import pathlib, shutil, sys, urllib.request
url = "https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime/1.20.0/onnxruntime-1.20.0.jar"
with urllib.request.urlopen(url, timeout=180) as source, pathlib.Path(sys.argv[1]).open("wb") as target:
    shutil.copyfileobj(source, target)
FETCH
  mv "$ort.download" "$ort"
fi
printf '%s  %s\n' "$expected" "$ort" | sha256sum --check --status || { echo 'ONNX_RUNTIME_HASH_MISMATCH' >&2; exit 1; }
install_dir="${2:-${IRIS_INSTALL_DIR:-/usr/irissys}}"
lib="${install_dir%/}/dev/java/lib/1.8"
pex="$lib/intersystems-pex-1.0.0-shaded.jar"
jdbc="$lib/intersystems-jdbc-3.11.0.jar"
# Recompile into a private temporary directory and atomically publish a fully built JAR.
classes="$(mktemp -d "$target/classes.XXXXXXXX")"
trap 'rm -rf "$classes"' EXIT
javac --release 11 -encoding UTF-8 -cp "$pex:$jdbc:$ort" -d "$classes" "$source_dir"/src/medaudit/pex/*.java
# Stable timestamps and no generated manifest make repeated builds byte-identical with the same JDK.
find "$classes" -exec touch -t 202611120000 {} +
jar --create --no-manifest --file "$target/medaudit-pex.jar.new" -C "$classes" .
mv "$target/medaudit-pex.jar.new" "$target/medaudit-pex.jar"
echo MEDAUDIT_JAVA_BUILD_OK
