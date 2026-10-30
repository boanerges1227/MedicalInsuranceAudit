#!/usr/bin/env bash
set -euo pipefail
# Start the isolated demo; container initialization does not require host Python.
cd "$(dirname "$0")/.."
docker compose up -d
# 从 Compose 实际端口映射读取地址，兼容 .env 中的本机端口配置。
bound_port=$(docker compose port iris 52773)
printf 'Workbench: http://127.0.0.1:%s/med-audit/\n' "${bound_port##*:}"
printf 'Username: medreview\nPassword: docker compose exec -T iris cat /durable/iris/private/med-audit-reviewer-password\n'
