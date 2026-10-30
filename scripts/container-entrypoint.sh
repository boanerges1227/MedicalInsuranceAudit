#!/usr/bin/env bash
set -euo pipefail
# Start the official IRIS process; this wrapper initializes the project in the same container.
private_dir=/durable/iris/private
if [[ -d "$private_dir" ]]; then rm -f "$private_dir/med-audit-ready"; fi
/iris-main "$@" &
iris_pid=$!
# Forward termination signals to the official process so it can shut down normally.
terminate() { if [[ -n "${worker_pid:-}" ]]; then kill -TERM "$worker_pid" 2>/dev/null || true; fi; kill -TERM "$iris_pid" 2>/dev/null || true; wait "$iris_pid" || true; }
trap terminate TERM INT
ready=0
for attempt in $(seq 1 120); do
  if ! kill -0 "$iris_pid" 2>/dev/null; then echo 'IRIS_MAIN_EXITED' >&2; exit 1; fi
  if iris session IRIS -U USER <<< 'write "READY",!' 2>/dev/null | grep -q READY; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then echo 'IRIS_NOT_READY' >&2; terminate; exit 1; fi
# Create the private directory after the initial IRIS migration to preserve data directory initialization.
mkdir -p "$private_dir" "$private_dir/fhir-inbox"
# 每个数据卷只处理一次 _SYSTEM 的首次改密标记；绝不重置或覆盖现有密码。
if [[ "${MED_AUDIT_DEFAULT_LOGIN_NO_CHANGE:-1}" == 1 && ! -f "$private_dir/med-audit-default-login-initialized" ]]; then
  login_setup=$(iris session IRIS -U %SYS <<'IRIS'
set sc=##class(Security.Users).UnExpireUserPasswords("_SYSTEM",.count)
if $system.Status.IsOK(sc) { write "DEFAULT_LOGIN_SETUP_OK",! } else { write "DEFAULT_LOGIN_SETUP_ERROR",! }
halt
IRIS
)
  if [[ "$login_setup" != *DEFAULT_LOGIN_SETUP_OK* || "$login_setup" == *DEFAULT_LOGIN_SETUP_ERROR* ]]; then
    echo 'DEFAULT_LOGIN_SETUP_FAILED' >&2
    terminate
    exit 1
  fi
  touch "$private_dir/med-audit-default-login-initialized"
fi
# Store the initial local demo administrator password in the isolated volume; never print it in startup logs.
password_file="$private_dir/med-audit-reviewer-password"
if [[ ! -f "$password_file" ]]; then
  if [[ -f "$private_dir/med-audit-initialized" ]]; then echo 'REVIEWER_PASSWORD_MISSING' >&2; terminate; exit 1; fi
  umask 077
  python3 -c 'import secrets; print("Demo1!"+secrets.token_hex(16))' > "$password_file"
fi
# Install the vector table before compiling dependent static SQL, then import the fictional fixtures.
output=$(iris session IRIS -U USER <<'IRIS'
try { set sc=$SYSTEM.OBJ.Load("/workspace/src/HD/NationalVector.cls","ck") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } do ##class(HD.NationalVector).Install() set sc=$SYSTEM.OBJ.LoadDir("/workspace/src","ck",,1) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } do ##class(HD.NationalVector).Import("/workspace/samples/demo-policy-vectors.jsonl") do ##class(HD.Setup).Install() do ##class(HD.DemoSetup).EnsureReviewer() do ##class(HD.Workflow).EnsureRole() write "CLEAN_BOOTSTRAP_OK",! } catch ex { write "CLEAN_BOOTSTRAP_ERROR=",ex.DisplayString(),! }
halt
IRIS
)
printf '%s\n' "$output"
if [[ "$output" != *CLEAN_BOOTSTRAP_OK* || "$output" == *CLEAN_BOOTSTRAP_ERROR* || "$output" == *"Detected "*" errors"* ]]; then terminate; exit 1; fi
touch "$private_dir/med-audit-initialized" "$private_dir/med-audit-ready"
echo 'REVIEWER_USER=medreview (password: docker compose exec -T iris cat /durable/iris/private/med-audit-reviewer-password)'
# Initialize in the background; an initial download failure does not block the core demo.
if [[ "${MED_AUDIT_ENABLE_UPLOAD_WORKER:-1}" == 1 ]]; then
  bash /workspace/scripts/upload-worker-entrypoint.sh &
  worker_pid=$!
fi
wait "$iris_pid"
