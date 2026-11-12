# Native AI traceability — DPI-I-689

This implementation addresses [DPI-I-689](https://ideas.intersystems.com/ideas/DPI-I-689) with native Interoperability messages for an actual AI Hub investigation. It is an implementation claim, not a claim of awarded contest points.

## Actual runtime boundary

`TraceTestService`/`FHIRIntake` → `AgentReview` → `RunTrace`, `ModelTrace`, `ToolTrace` uses native `SendRequestSync` and one existing `Ens.MessageHeader.SessionId`. The real `%AI.Agent.Chat` and real evidence tools execute inside `AgentReview`. Tool span IDs increase monotonically throughout the run, and the RAM-only pending tool buffer is capped at 64 observations. Exceeding this bound fails the investigation closed. New `HD.Trace.Event` messages contain a bounded, typed metadata allowlist. They have no arbitrary JSON payload, prompt, response text, tool arguments/results, HTTP headers, credential, or external exception-text field. `HD.Trace.Sink` validates this schema and acknowledges acceptance.

`TraceId` is generated on the server and links `RunId`, the event, and the case version. `NativeParentMessageId` is the actual AgentReview request-header ID. `SdkInvocationId=execution:<TraceId>` identifies this unsaved SDK invocation; it is **not** a persisted AI Hub session ID. No new `session.%Save()` or raw conversation persistence is introduced. `PromptVersion=hd-agent-v1` identifies the application prompt. Registered duplicate claims still bypass the model, and the existing authorization, evidence binding, stale-version checks, quota, human review and settlement behavior remain in force.

The native agent invokes Rust provider tokens internally, so overriding ObjectScript `Provider.ChatComplete` would miss the real loop. Instead, OpenAI-compatible, Qwen, Ollama, NIM and Anthropic calls use a short-lived loopback relay forwarding to the **same configured upstream**. Anthropic root URLs are normalized to `/v1/`. The relay observes each real HTTP request/response, including attempts in a multi-step tool loop. It adds no retry or fallback behavior. `Fallback=none`; repeated identical HTTP requests after a failure carry `RetryOf` and `RetryKind=identical-after-failure`. This is a narrowly observed relationship, not a claim about the SDK's retry intent. Changes in request content do not receive an invented retry link.

The observer uses a separate, temporary Python process. Upstream configuration crosses a private stdin pipe; original request/response bodies exist only in RAM. Only sanitized metadata returns to Embedded Python. Random loopback path tokens isolate each relay. Cleanup runs after SDK success and failure, with an additional child lifetime/parent-exit guard. No endpoints are added to a remote application or telemetry service.

**Timing:** Rust-to-ObjectScript tool callbacks must not reenter Embedded Python; this crashes the tested AI Hub SDK build. The audit policy therefore captures only sanitized tool metadata and actual timestamps in ObjectScript RAM. After `Chat` returns or fails, the worker drains relay metadata, merges actual timestamps with tool observations and sends native child messages. Native header timestamps show message emission time; `StartedAt`, `EndedAt` and `DurationMs` describe the real HTTP/tool observations. Native message creation is not a live streaming view of an unfinished SDK call.

Google Gemini's native provider rejects endpoint overrides, so its configured provider behavior is preserved and `Coverage=sdk-invocation-only` is explicit. Google shows invocation start/end, actual tool audits, and SDK aggregate usage when available; this implementation does **not** claim per-HTTP Google request, retry or error coverage. SDK zero default counters are not treated as proof of known usage. HTTP token counts remain absent with `UsageKnown=0` when an upstream omits usage. `CostKnown=0` always: no billable cost or invented token estimate is recorded.

Trace initialization failures block the model before calling it. A validated candidate remains in RAM until the final native trace acknowledgement and relay cleanup succeed. The worker then reacquires the case lock and checks the current event/version again before publishing; the earlier lock/version check is retained. Metadata persistence failures make the investigation fail closed and publish a failure instead of that candidate; human findings and settlement decisions are not changed. Configured direct `HD.Agent.Run` calls require a native trace scope (`TRACE_REQUIRED`); callers should use the Production service. The acknowledged `run.end` describes candidate processing and trace completion; the final `AgentReview` reply and registered job result also include the subsequent publication guard. A case version changed during acknowledgement can therefore produce a final `STALE_CASE` reply without publishing the candidate. Existing model-setting connection probes are separate from an investigation.

## Reproduce with synthetic data

Use an isolated container with fresh data and the repository mounted read-only at `/workspace`. No paid model or existing container/data is required or modified:

```sh
docker run -d --name med-689-validation \
  -v "$PWD:/workspace:ro" iris-community:2026.3.0AI.154.0
# Wait until this newly-created IRIS instance reports ready.
MED_TRACE_CONTAINER=med-689-validation python3 -m unittest discover \
  -s tests -p test_traceability_native.py -v
python3 -m unittest discover -s tests -p test_traceability_contract.py -v
python3 -m unittest discover -s tests -p test_trace_relay.py -v
```

The opt-in native test uses a local synthetic OpenAI HTTP fixture on container loopback. It compiles the actual application/SDK classes, starts `HD.Trace.TestProduction`, and verifies two actual model requests and two actual evidence tool calls for both OpenAI and Anthropic protocols, known usage (52 input / 20 output tokens), HTTP 400 failure, explicit unknown usage, concurrent worker isolation, native session/parent linkage, absence of synthetic key/tool/error secret markers from new trace events, and a deterministic final-ack gate proving success remains unpublished while the acknowledgement is pending, fails closed when rejected, and rechecks stale versions after acknowledgement. The test Production has two workers to exercise isolation; it does not change the application's single-active-registered-investigation rule. Relay transport tests additionally verify identical-request retry annotation, forwarding, privacy, timeouts, bounds and lifecycle behavior. A synthetic fixture result does not establish real-provider account compatibility or award eligibility.

Use the namespace in which the Production actually runs (`USER` in this container). Select one event and open its `NativeSessionId` in Management Portal → Interoperability → Visual Trace. The following SQL reads metadata only:

```sql
SELECT ID, TraceId, RunId, EventId, CaseVersion, NativeSessionId,
       NativeParentMessageId, Kind, SpanId, ParentSpanId, Sequence,
       AttemptSequence, StartedAt, EndedAt, DurationMs,
       Provider, Model, HttpStatus, Status, ErrorCode,
       UsageKnown, InputTokens, OutputTokens, CostKnown,
       ToolName, ToolCallCount, Coverage, RetryOf, RetryKind, Fallback
FROM HD_Trace.Event
ORDER BY ID DESC;

SELECT ID, SessionId, SourceConfigName, TargetConfigName,
       MessageBodyClassName, MessageBodyId, CorrespondingMessageId,
       TimeCreated, TimeProcessed, Status
FROM Ens.MessageHeader
WHERE SessionId = <NativeSessionId>
ORDER BY ID;
```

All new `HD.Trace.Event` headers in that run have source `AgentReview`, the same native session and the actual root request in `NativeParentMessageId`; span IDs provide the payload-level model/tool hierarchy. `Sequence` is native metadata emission order, and `AttemptSequence` is the HTTP attempt number extracted from `http-N`. A tool's `ParentSpanId` identifies the model response that requested it.

## Scope compared with Langfuse

The native trace keeps Production routing, AI invocation, actual HTTP/tool metadata and the run result together inside IRIS, with no external telemetry export. Langfuse remains a broader observability product, including its own prompt/evaluation, dataset and cross-service analysis workflows. This change does not reproduce that platform or claim feature parity. It deliberately excludes raw prompts, completions and tool content, so those cannot be inspected in its new native messages. Google HTTP internals and live in-progress message emission are explicit limits.

## 中文说明

本实现针对 [DPI-I-689](https://ideas.intersystems.com/ideas/DPI-I-689)，把真实 `%AI.Agent.Chat` 调用、实际 HTTP 请求/响应和实际工具执行的**元数据**放到同一次原生 Production Visual Trace。此说明不代表已经获得比赛加分。

`AgentReview` 保留真实 SDK 调用；通过原生同步子消息发送到 `ModelTrace`、`ToolTrace`、`RunTrace`。`TraceId` 由服务端生成，关联任务、事件、病例版本、原生会话和真实父消息。新增消息只有严格限定的类型化字段，不含提示词、模型正文、工具参数或结果、密钥和外部异常原文。SDK 会话不新增持久化；`SdkInvocationId` 仅标识本次未保存的 SDK 执行。

OpenAI 兼容协议、Qwen、Ollama、NIM 和 Anthropic 使用临时本地转发进程观察真实 HTTP，仍访问原配置上游，不新增重试和回退。配置通过私有管道传入，原始正文只存在内存中。SDK 工具审计回调只在 ObjectScript 内存中记录允许的元数据；实测该回调重入 Embedded Python 会导致 SDK 进程崩溃，因此在 SDK 返回或失败后合并实际时间并生成原生子消息。原生消息头时间是发送时间，载荷中的时间和耗时才是实际观测时间。

Google 原生 SDK 不支持端点覆盖，保留其原调用行为并明确标记 `sdk-invocation-only`，只展示 SDK 调用、工具审计和可得的汇总，不声称看到了 Google 每次 HTTP 请求或重试。未提供 token 用量时明确 `UsageKnown=0`，费用始终未知，不虚构用量或费用。

上方命令仅在全新的 `med-689-*` 容器中运行本地合成模型，验证真实原生 SDK 的两轮 HTTP、两个工具、失败、隐私、未知用量、并发隔离和原生父子关联。需在实际 Production 命名空间查询 `HD_Trace.Event`，按 `NativeSessionId` 打开 Visual Trace。人工复核、证据引用、鉴权、版本保护、登记任务去重和日限额保持原逻辑；追踪无法初始化时阻止模型调用；经验证的候选建议只保留内存，最终追踪确认及清理成功后，再次加病例锁并检查事件/版本才发布。保留之前的加锁检查；追踪确认失败时不发布候选成功建议，任务与模型建议按失败处理，不影响人工决定和医保结算。此原生能力不替代 Langfuse 的提示词、评测、数据集和跨服务分析平台功能。
