# Java PEX runtime dependencies

The project Java classes use the PEX and JDBC libraries supplied by InterSystems IRIS; those libraries are not redistributed in this repository.

ONNX Runtime Java 1.20.0 is downloaded from [Maven Central](https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime/1.20.0/) on first build and verified with SHA-256 `c46608681692b3693914defb42fa3119ad7cb6146870581ece247e0ed5793fe8`. Its JAR includes the Linux x86-64 and aarch64 CPU native libraries. ONNX Runtime is MIT licensed; its upstream license and third-party notices are included in the dependency JAR. [Upstream project](https://github.com/microsoft/onnxruntime/tree/v1.20.0).

The model and tokenizer remain separately provisioned private assets with existing pinned hashes. Neither is redistributed by this module. A SHA-256 mismatch fails closed. Offline installations may preseed the exact ONNX Runtime JAR in the runtime directory printed by `HD.PEX.Setup.RuntimeRoot()` before startup.

## Pinned tokenizer Unicode properties

`PinnedUnicode.java` is generated from every Unicode scalar using the exact `tokenizers==0.23.3` runtime pinned by `requirements/upload-worker.txt` and tokenizer SHA-256 `48cea5d44424912a6fd1ea647bf4fe50b55ab8b1e5879c3275f80e339e8fae26`. It records actual BERT normalizer drop/space/Chinese-separation sets and pretokenizer punctuation sets, independently of the JDK's Unicode version. The blank-input predicate separately matches Python 3.12 `str.isspace()`.

To regenerate in an environment with those pinned dependencies and model assets:

```sh
python3 java/generate_unicode_tables.py /durable/iris/private/upload-model/tokenizer.json java/src/medaudit/pex/PinnedUnicode.java
```

The generator validates the runtime version and tokenizer hash, scans all 1,112,064 valid Unicode scalars, and embeds a SHA-256 fingerprint of its range tables in the generated Java source. It is a maintenance tool; Java inference does not invoke Python.
