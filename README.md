# IORedis for Dart

A high-performance Redis client for Dart with support for command retries,
connection pooling, pipelines, transactions, pub/sub, and binary-safe payloads.

## Features

- Connection management with auto-reconnect
- RESP3 by default (`HELLO 3`) with automatic fallback to RESP2 when unsupported
- Retry policies with backoff and jitter
- Pipelines with configurable batch size
- MULTI/EXEC and WATCH-based optimistic transactions
- Pub/Sub (`SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE`)
- Binary-safe APIs (`setBuffer` / `getBuffer`)
- Generic command API for full Redis command coverage (`command` / `sendObjectCommand`)
- Scan iterators (`scanIterator`, `hscanIterator`, `sscanIterator`, `zscanIterator`)
- Script helpers (`eval`, `evalsha`, `scriptLoad`)
- RedisJSON helpers (`jsonSet`, `jsonGet`) when module is installed

## Installation

```yaml
dependencies:
  ioredis: ^latest_version
```

```bash
dart pub get
```

## Quick Start

```dart
import 'package:ioredis/ioredis.dart';

Future<void> main() async {
  final redis = Redis(RedisOptions(
    host: '127.0.0.1',
    port: 6379,
    db: 0,
  ));

  try {
    await redis.set('hello', 'world');
    final value = await redis.get('hello');
    print(value); // world
  } finally {
    await redis.disconnect();
  }
}
```

## Configuration

```dart
final redis = Redis(RedisOptions(
  host: '127.0.0.1',
  port: 6379,
  password: 'secret',
  db: 1,
  connectTimeout: const Duration(seconds: 10),
  commandTimeout: const Duration(seconds: 5),
  // Default is 3 (RESP3). If HELLO is unsupported, it falls back to RESP2.
  protocolVersion: 3,
  // Keep RESP3 attribute wrappers instead of returning only wrapped data.
  preserveResp3Attributes: false,
  // Receive RESP3 push messages like invalidation notifications.
  onPush: (push) {
    print('push => ${push.items}');
  },
  // Receive packets that arrive without a pending command (for MONITOR, etc).
  onUnmatchedPacket: (packet) {
    print('unmatched => $packet');
  },
  maxConnection: 10,
  idleTimeout: const Duration(seconds: 10),
  pipelineBatchSize: 256,
  maxPendingCommands: 10000,
  retryPolicy: const RedisRetryPolicy(
    maxAttempts: 3,
    initialDelay: Duration(milliseconds: 50),
    maxDelay: Duration(seconds: 2),
    jitter: RedisRetryJitter.full,
  ),
  onEvent: (event) {
    print('${event.type} ${event.command} ${event.duration}');
  },
));
```

## RESP2 / RESP3 behavior

- Default protocol is RESP3 (`protocolVersion: 3`).
- On servers that do not support `HELLO`, the client automatically downgrades to RESP2 for that connection.
- You can force RESP2 by setting `protocolVersion: 2`.
- RESP3 push frames are available via `RedisOptions.onPush`.
- RESP3 attributes are parsed; set `preserveResp3Attributes: true` to keep wrappers in command replies.

## Core API Coverage

### Basic values

```dart
await redis.set('k1', 'v1');
final v1 = await redis.get('k1');

await redis.set('k2', 'v2');
final values = await redis.mget(<String>['k1', 'k2', 'missing']);
await redis.mdelete(<String>['k1', 'k2']);
```

### Generic command API

```dart
await redis.command('SET', args: <Object?>['k1', 'v1']);
final v1 = await redis.command('GET', args: <Object?>['k1']);
```

### Pipeline

```dart
final replies = await (redis.pipeline()
      ..set('pipe:1', 'a')
      ..set('pipe:2', 'b')
      ..get('pipe:1')
      ..get('pipe:2'))
    .exec(batchSize: 2);
```

### MULTI/EXEC

```dart
final replies = await (redis.multi()
      ..set('tx:1', 'x')
      ..set('tx:2', 'y')
      ..get('tx:1')
      ..get('tx:2'))
    .exec();
```

### WATCH optimistic transaction

```dart
final tx = await redis.watch(<String>['inventory:item:42']);
tx.set('inventory:item:42', 'in_stock');
final execResult = await tx.exec();
if (execResult == null) {
  // watched key changed by another client
}
```

### Pub/Sub

Use separate connections for publisher and subscriber.

```dart
final sub = redis.duplicate();
final pub = redis.duplicate();

final listener = await sub.subscribe('room');
listener.onMessage = (channel, message) {
  print('$channel => $message');
};

await pub.publish('room', 'hello');
```

### Binary payloads

```dart
final bytes = Uint8List.fromList(<int>[0, 1, 2, 3, 255]);
await redis.setBuffer('raw:key', bytes);
final out = await redis.getBuffer('raw:key');
```

### Script helpers

```dart
const script = 'return ARGV[1]';
final sha = await redis.scriptLoad(script);
final value = await redis.evalsha(sha, args: <dynamic>['ok']);
```

### Scan iterators

```dart
await for (final key in redis.scanIterator(match: 'user:*', count: 100)) {
  print(key);
}
```

### RedisJSON (optional module)

```dart
await redis.jsonSet('user:1', '.', {'name': 'alice'});
final full = await redis.jsonGet('user:1', '.');
final name = await redis.jsonGet('user:1', '.name');
```

## TODO: Missing First-Class Command Wrappers

All commands below are still callable via `command(...)`, `sendCommand(...)`, or
`sendObjectCommand(...)`. This list tracks convenience APIs that are still
missing.

### RESP2/Core command families

- [ ] Generic key ops (`EXISTS`, `EXPIRE`, `TTL`, `PTTL`, `TYPE`, `RENAME`, `COPY`, `UNLINK`)
- [ ] String ops beyond `SET`/`GET` (`SETEX`, `PSETEX`, `GETSET`, `STRLEN`, `APPEND`, `MSET`, `MSETNX`, `SETRANGE`, `GETRANGE`)
- [ ] Hash/list/set/zset coverage expansion (`HDEL`, `HGETALL`, `HINCRBY`, `LPOP`, `RPOP`, `BLPOP`, `SREM`, `SISMEMBER`, `ZREM`, `ZCARD`, `ZRANK`, `ZREVRANGE`)
- [ ] Streams coverage expansion (`XREAD`, `XREADGROUP`, `XGROUP`, `XACK`, `XDEL`, `XTRIM`)
- [ ] Transactions and CAS helpers (`DISCARD`, `WATCH`/`UNWATCH` helper variants, `MULTI` builder parity)
- [ ] Server/admin wrappers (`PING`, `INFO`, `DBSIZE`, `TIME`, `CONFIG`, `CLIENT`, `COMMAND`, `SLOWLOG`, `LATENCY`)
- [ ] Pub/Sub helper parity (`PUBSUB CHANNELS/NUMSUB/NUMPAT/SHARD*`)

### RESP3-focused features

- [ ] HELLO convenience wrapper options (`SETNAME`, client metadata helpers)
- [ ] Client-side caching wrappers (`CLIENT TRACKING`, `CLIENT CACHING`, redirect helpers)
- [ ] ACL wrappers (`ACL CAT`, `ACL LIST`, `ACL GETUSER`, `ACL SETUSER`, etc.)
- [ ] Function API wrappers (`FUNCTION LOAD`, `FUNCTION LIST`, `FCALL`, `FCALL_RO`)
- [ ] Extended RESP3 push helper APIs (typed events for non Pub/Sub push kinds)

## Example and Benchmark

- Example application: `example/ioredis_example.dart`
- Benchmark suite: `benchmark/performance_test.dart`

Run benchmark:

```bash
dart run benchmark/performance_test.dart
```

## Testing

```bash
dart test
```

By default tests use `127.0.0.1:6379`. You can override with:

- `REDIS_HOST`
- `REDIS_PORT`
- `REDIS_PASSWORD`
- `REDIS_DB_IOREDIS`

## Requirements

- Dart SDK 2.19+
- Redis server 6+ recommended
- RedisJSON only if using `jsonSet`/`jsonGet`

## License

MIT
