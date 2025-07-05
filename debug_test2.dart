import 'package:ioredis/ioredis.dart';

void main() async {
  // Test if keyPrefix can somehow be bypassed
  final redis =
      Redis(RedisOptions(host: '127.0.0.1', port: 6379, password: 'pass'));
  final localRedis = Redis(RedisOptions(
      keyPrefix: 'dox', host: '127.0.0.1', port: 6379, password: 'pass'));

  try {
    // Set key1 without prefix (simulating the "race request" test)
    await redis.set('key1', 'redis1');
    print('Set key1=redis1 (no prefix)');

    // Now try to get key1 with the prefixed redis instance
    final s1 = await localRedis.get('key1');
    print('localRedis.get("key1") = $s1 (should be null)');

    // Check what the prefixed instance is actually looking for
    print(
        'localRedis with prefix "dox" looking for key1 should search for "dox:key1"');

    // Let's manually check if dox:key1 exists
    final manualCheck = await redis.get('dox:key1');
    print('redis.get("dox:key1") = $manualCheck');

    // Let's also verify the actual keyPrefix value
    print('localRedis.option.keyPrefix = "${localRedis.option.keyPrefix}"');
  } finally {
    await redis.disconnect();
    await localRedis.disconnect();
  }
}
