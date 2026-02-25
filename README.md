# IORedis for Dart

A high-performance Redis client for Dart with support for command retries,
connection pooling, pipelines, transactions, pub/sub, and binary-safe payloads.

## Features

- Connection management with auto-reconnect
- Optional RESP3 (`HELLO 3`) support
- Retry policies with backoff and jitter
- Pipelines with configurable batch size
- MULTI/EXEC and WATCH-based optimistic transactions
- Pub/Sub (`SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE`)
- Binary-safe APIs (`setBuffer` / `getBuffer`)
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
  protocolVersion: 3,
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

## Core API Coverage

### Basic values

```dart
await redis.set('k1', 'v1');
final v1 = await redis.get('k1');

await redis.set('k2', 'v2');
final values = await redis.mget(<String>['k1', 'k2', 'missing']);
await redis.mdelete(<String>['k1', 'k2']);
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
