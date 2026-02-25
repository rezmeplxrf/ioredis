# Redis Dart Client Fix Plan

## Scope
This plan prioritizes correctness and reliability first, then feature parity with mainstream Redis clients (redis-py, node-redis, Jedis, go-redis), and finally performance/ergonomics.

## Status Snapshot (2026-02-25)
- `P0`: Completed
- `P1`: Completed
- `P2`: Completed
- `P3`: Partially completed
- `P4`: Not started

## Remaining From This Plan
- `13) Redis Cluster support`: implemented baseline plus opt-in integration test for live slot re-assignment and MOVED recovery (`REDIS_CLUSTER_INTEGRATION=1`); ASK and multi-node migration orchestration scenario coverage can be expanded.
- `14) Sentinel support`: implemented baseline (Sentinel master discovery + refresh API + READONLY-triggered refresh) plus opt-in integration coverage for live discovery/routing; full failover simulation coverage with Sentinel quorum election still missing.
- `15) Parser allocation reduction`: implemented for byte-stream transformer via sliding buffer + compaction (removes per-message full copy/removeRange path); benchmark numbers still to be recorded in a non-sandboxed environment.
- `16) Pipeline throughput tuning`: implemented baseline via configurable `pipelineBatchSize` chunking and `maxPendingCommands` backpressure cap to bound memory during large bursts.
- `17) Instrumentation hooks`: implemented baseline structured events (connect/reconnect/disconnect/command success+retry+error/cluster redirects/sentinel resolve); metrics-focused docs and examples can be expanded.

## P0: Correctness and Reliability (Immediate)

### 1) Fix client mode bug after publish
- Problem: `publish()` sets `redisClientType = publisher` permanently, preventing later subscribe calls on same client.
- Files:
  - `lib/src/redis.dart`
- Changes:
  - Remove sticky `publisher` state or reset state after publish completes.
  - Keep only `subscriber` as sticky state while active subscriptions exist.
- Tests:
  - Add test: publish on fresh client, then subscribe succeeds.

### 2) Re-subscribe after reconnect
- Problem: after reconnect, existing subscription callbacks remain in memory but no `SUBSCRIBE/PSUBSCRIBE` replay is sent.
- Files:
  - `lib/src/redis_connection.dart`
  - `lib/src/redis.dart`
- Changes:
  - Add reconnect hook to replay all active subscriptions.
  - Ensure replay order and idempotency (avoid duplicate listener registration).
  - Update client mode refresh based on real subscription state.
- Tests:
  - Add integration test: subscribe -> force disconnect -> reconnect -> publish -> callback still receives.

### 3) Transaction safety and pinning
- Problem: MULTI flow is not connection-pinned and has no DISCARD on intermediate failure.
- Files:
  - `lib/src/redis_multi_command.dart`
  - `lib/src/redis.dart`
  - `lib/src/redis_connection.dart`
- Changes:
  - Execute `MULTI` sequence on one dedicated connection.
  - On any command failure between `MULTI` and `EXEC`, issue `DISCARD` best-effort.
  - Prevent pool fallback during active transaction.
- Tests:
  - Add test for failure during queued commands verifies DISCARD.
  - Add concurrency test that transaction does not mix with external commands.

### 4) Replace runtime `print` in protocol paths
- Problem: parser and connection paths log with `print`, causing noisy output and weak observability control.
- Files:
  - `lib/src/redis_connection.dart`
- Changes:
  - Route through `option.onError` and avoid direct stdout logging.
  - Add fallback no-op or structured error wrapper.
- Tests:
  - Add unit test ensuring no direct print side effects on malformed packets.

## P1: Protocol and API Semantics

### 5) Integer response typing
- Problem: RESP integer currently returned as String.
- Files:
  - `lib/src/redis_response.dart`
  - public API wrappers as needed
- Changes:
  - Parse `:<num>\r\n` as `int`.
  - Audit wrappers/tests for expected dynamic types.
- Tests:
  - Add parser tests for positive/negative integer and nested arrays with integers.

### 6) Binary-safe API baseline
- Problem: UTF-8 string stream/parser is not fully safe for arbitrary binary payloads.
- Files:
  - `lib/src/transformer.dart`
  - `lib/src/redis_response.dart`
  - encoder/API surfaces
- Changes:
  - Introduce byte-buffer RESP parser.
  - Add API variants for `Uint8List` values/keys and raw replies.
  - Keep string API as convenience layer.
- Tests:
  - Invalid UTF-8 payload roundtrip tests.
  - Null bytes and random binary corpus tests.

### 7) Documentation correctness
- Problem: README references unsupported option `retryAttempts`.
- Files:
  - `README.md`
- Changes:
  - Replace with actual `retryPolicy` usage.
  - Document reconnect behavior and command retry semantics explicitly.
- Tests:
  - N/A (doc-only), but validate snippets compile in example tests if possible.

## P2: Feature Parity Expansion

### 8) Core command coverage expansion
- Missing: broad wrappers for hash/list/set/zset/stream/geo/scripting/transactions.
- Files:
  - `lib/src/redis.dart` (+ split into command groups if needed)
- Changes:
  - Add thin wrappers for high-usage command families first.
  - Keep generic `sendCommand` for long-tail commands.
- Tests:
  - Add targeted integration tests per command family.

### 9) Script workflow improvements
- Missing: `SCRIPT LOAD`, `EVALSHA`, cache-oriented helpers.
- Changes:
  - Add APIs and fallback strategy (`NOSCRIPT` -> optional reload).
- Tests:
  - Script load/evalsha happy path and NOSCRIPT behavior.

### 10) Scan iterators
- Missing: ergonomic cursor iteration.
- Changes:
  - Add async iterators for `SCAN`, `HSCAN`, `SSCAN`, `ZSCAN`.
- Tests:
  - Large keyspace scan correctness and cursor completion.

### 11) Pub/Sub enhancements
- Missing: sharded pub/sub (`SSUBSCRIBE` etc.) and richer callback metadata.
- Changes:
  - Extend subscriber model and pushed message handling.
- Tests:
  - Add sharded channel tests.

## P3: Advanced Topologies and Protocol

### 12) RESP3 support
- Implement `HELLO 3`, RESP3 data types, push-type parsing.
- Ensure backward compatibility with RESP2.
- Tests:
  - Parser conformance tests for RESP3 types.

### 13) Redis Cluster support
- Add slot cache, MOVED/ASK handling with redirect retries, topology refresh.
- Tests:
  - Cluster integration tests (including slot migration scenario).

### 14) Sentinel support
- Add discovery/failover workflow for master resolution.
- Tests:
  - Sentinel failover integration test.

## P4: Performance and Observability

### 15) Parser allocation reduction
- Replace string concatenation + slicing loop with ring/byte buffer.
- Benchmark against current parser on large pipelines.

### 16) Pipeline throughput tuning
- Revisit batching strategy and queue memory behavior under high in-flight load.
- Add backpressure strategy for very large command bursts.

### 17) Instrumentation hooks
- Add structured events for connect/reconnect/command-latency/retry.
- Optional metrics callback API.

## Delivery Milestones
1. Milestone A (P0): correctness fixes merged with tests.
2. Milestone B (P1): integer typing + binary-safe baseline + docs corrections.
3. Milestone C (P2): command coverage and script/scan/pubsub improvements.
4. Milestone D (P3/P4): RESP3 + cluster/sentinel + perf/instrumentation.

## Suggested Implementation Order
1. P0.1 publish mode fix
2. P0.2 resubscribe on reconnect
3. P0.3 transaction pinning + DISCARD safety
4. P1.5 integer parsing
5. P1.6 binary-safe parser groundwork
6. P1.7 README fixes
