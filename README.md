# IORedis for Dart

A high-performance Redis client for Dart that provides a simple, intuitive API for Redis operations with support for both individual and bulk operations.

## Features

- ✅ **High Performance**: Optimized for speed with connection pooling
- ✅ **Comprehensive Redis Support**: Supports most Redis commands including GET, SET, MGET, DELETE, etc.
- ✅ **Pub/Sub Support**: Full publisher/subscriber pattern support
- ✅ **JSON Support**: RedisJSON module operations for JSON documents
- ✅ **UTF-8 & Unicode**: Full Unicode and UTF-8 support including emojis
- ✅ **Connection Management**: Automatic reconnection with retry strategies
- ✅ **Type Safety**: Strongly typed API with null safety
- ✅ **Bulk Operations**: Efficient bulk get/set/delete operations

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  ioredis: ^latest_version
```

Then run:

```bash
dart pub get
```

## Quick Start

### Basic Usage

```dart
import 'package:ioredis/ioredis.dart';

void main() async {
  // Create Redis connection
  final redis = Redis(RedisOptions(
    host: '127.0.0.1',
    port: 6379,
    password: 'your_password', // optional
    db: 0, // optional, default database
  ));

  // Set a value
  await redis.set('key', 'value');

  // Get a value
  final value = await redis.get('key');
  print(value); // Output: value

  // Don't forget to disconnect when done
  await redis.disconnect();
}
```

### Advanced Configuration

```dart
final redis = Redis(RedisOptions(
  host: 'localhost',
  port: 6379,
  password: 'secret',
  db: 1,
  connectTimeout: Duration(seconds: 10),
  commandTimeout: Duration(seconds: 5),
  retryAttempts: 3,
));
```

## API Reference

### Basic Operations

#### SET / GET

```dart
// Set a string value
await redis.set('user:1:name', 'John Doe');

// Get a string value
final name = await redis.get('user:1:name');
print(name); // John Doe

// Set with expiration (seconds)
await redis.set('session:abc', 'user123', 'EX', 3600);
```

#### Multiple GET (MGET)

```dart
// Set multiple values
await redis.set('key1', 'value1');
await redis.set('key2', 'value2');
await redis.set('key3', 'value3');

// Get multiple values in one operation
final values = await redis.mget(['key1', 'key2', 'key3', 'non_existent']);
print(values); // ['value1', 'value2', 'value3', null]

// Handle empty key list
final empty = await redis.mget([]);
print(empty); // []
```

#### DELETE Operations

```dart
// Delete a single key
await redis.delete('key1');

// Delete multiple keys
await redis.mdelete(['key1', 'key2', 'key3']);
```

#### Database Operations

```dart
// Clear current database
await redis.flushdb();

// Use custom socket (advanced)
final customRedis = Redis();
customRedis.setSocket(await Socket.connect('127.0.0.1', 6379));
```

### Pub/Sub Operations

```dart
// Create subscriber
final subscriber = Redis(RedisOptions(host: '127.0.0.1', port: 6379));

// Subscribe to a channel
final channelSubscriber = await subscriber.subscribe('chat_room');
channelSubscriber.onMessage = (String channel, String? message) {
  print('Channel: $channel, Message: $message');
};

// Subscribe to pattern
final patternSubscriber = await subscriber.psubscribe('user:*');
patternSubscriber.onMessage = (String pattern, String? message) {
  print('Pattern: $pattern, Message: $message');
};

// Publisher (use separate connection)
final publisher = subscriber.duplicate();
await publisher.publish('chat_room', 'Hello everyone!');
await publisher.publish('user:123', 'Personal message');
```

### JSON Operations (RedisJSON Module)

```dart
// Set JSON document
final userData = {
  'name': 'Alice',
  'age': 30,
  'preferences': {
    'theme': 'dark',
    'notifications': true
  }
};

await redis.jsonSet('user:1', '.', userData);

// Get entire JSON document
final fullDoc = await redis.jsonGet('user:1', '.');
print(fullDoc);

// Get specific JSON path
final name = await redis.jsonGet('user:1', '.name');
print(name); // Contains "Alice"

final age = await redis.jsonGet('user:1', '.age');
print(age); // Contains "30"
```

## Working with Different Data Types

### Unicode and Emojis

```dart
// Full Unicode support
await redis.set('greeting', 'မင်္ဂလာပါ'); // Burmese
await redis.set('emoji', '🚀 Hello 世界 🌍');

final greeting = await redis.get('greeting');
final emoji = await redis.get('emoji');
print('$greeting $emoji');
```

### Binary Data

```dart
// Store binary-like data
await redis.set('binary', 'Hello\x00World\x01\x02\x03');
final binary = await redis.get('binary');
print(binary); // Preserves null bytes and special characters
```

### Large Values

```dart
// Handle large strings (MB size)
final largeValue = 'x' * 1024 * 1024; // 1MB string
await redis.set('large_key', largeValue);
final retrieved = await redis.get('large_key');
print(retrieved.length); // 1048576
```

### JSON Strings

```dart
// Store JSON as strings
final jsonString = '{"users": [{"id": 1, "name": "John"}]}';
await redis.set('data', jsonString);
final data = await redis.get('data');
// Parse with dart:convert if needed
final parsed = jsonDecode(data!);
```

## Connection Management

### Using Connection Pools

```dart
// The library automatically manages connection pooling
final redis = Redis(RedisOptions(
  host: '127.0.0.1',
  port: 6379,
  // Pool will be created automatically
));
```

### Multiple Databases

```dart
// Connect to different databases
final db0 = Redis(RedisOptions(db: 0));
final db1 = Redis(RedisOptions(db: 1));

await db0.set('key', 'value0');
await db1.set('key', 'value1');

final val0 = await db0.get('key'); // value0
final val1 = await db1.get('key'); // value1
```

### Duplicate Connections

```dart
final redis1 = Redis(RedisOptions(host: '127.0.0.1'));
final redis2 = redis1.duplicate(); // Same configuration, separate connection

// Both operate on the same database
await redis1.set('shared', 'data');
final data = await redis2.get('shared'); // 'data'
```

## Error Handling

```dart
try {
  final redis = Redis(RedisOptions(
    host: 'nonexistent-host',
    connectTimeout: Duration(seconds: 5),
  ));
  
  await redis.set('key', 'value');
} catch (e) {
  print('Connection failed: $e');
}
```

## Best Practices

### 1. Always Close Connections

```dart
final redis = Redis(RedisOptions(host: '127.0.0.1'));
try {
  // Your operations here
  await redis.set('key', 'value');
} finally {
  await redis.disconnect();
}
```

### 2. Use Bulk Operations for Multiple Keys

```dart
// ❌ Inefficient - multiple round trips
for (final key in keys) {
  await redis.get(key);
}

// ✅ Efficient - single round trip
final values = await redis.mget(keys);
```

### 3. Handle Null Values

```dart
final value = await redis.get('might_not_exist');
if (value != null) {
  print('Value exists: $value');
} else {
  print('Key does not exist');
}
```

### 4. Use Connection Pooling for High-Throughput Applications

```dart
// The library handles connection pooling automatically
// Just create your Redis instance and reuse it
final redis = Redis(RedisOptions(host: '127.0.0.1'));

// Use the same instance for multiple operations
await Future.wait([
  redis.set('key1', 'value1'),
  redis.set('key2', 'value2'),
  redis.set('key3', 'value3'),
]);
```

## Performance Tips

- Use `mget()` instead of multiple `get()` calls
- Use `mdelete()` instead of multiple `delete()` calls
- Reuse Redis connections instead of creating new ones
- Use appropriate key naming conventions
- Consider using JSON operations for complex data structures

## Examples

Check out the `example/` directory for more comprehensive examples:

- `ioredis_example.dart` - Basic usage examples
- `benchmark/performance_test.dart` - Performance benchmarks

## Requirements

- Dart SDK 2.19.0 or higher
- Redis server 3.0 or higher
- For JSON operations: RedisJSON module

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
