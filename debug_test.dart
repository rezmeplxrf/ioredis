import 'package:ioredis/ioredis.dart';

void main() async {
  // Test keyPrefix behavior
  final redis =
      Redis(RedisOptions(host: '127.0.0.1', port: 6379, password: 'pass'));
  final localRedis = Redis(RedisOptions(
      keyPrefix: 'dox', host: '127.0.0.1', port: 6379, password: 'pass'));

  try {
    // Clear any existing data
    await redis.delete('key1');
    await redis.delete('foo');
    await redis.delete('dox:foo');
    await redis.delete('dox:key1');

    // Set key1 without prefix
    await redis.set('key1', 'redis1');
    print('Set key1=redis1 (no prefix)');

    // Set foo with prefix
    await localRedis.set('foo', 'redis1');
    print('Set foo=redis1 (with prefix dox)');

    // Try to get key1 with prefix (should look for dox:key1)
    final s1 = await localRedis.get('key1');
    print('localRedis.get("key1") = $s1');

    // Try to get foo with prefix (should look for dox:foo)
    final s1b = await localRedis.get('foo');
    print('localRedis.get("foo") = $s1b');

    // Get dox:foo without prefix
    final s2 = await redis.get('dox:foo');
    print('redis.get("dox:foo") = $s2');

    // Check what keys exist
    print('\nChecking what keys exist:');
    final key1Val = await redis.get('key1');
    print('redis.get("key1") = $key1Val');

    final doxKey1Val = await redis.get('dox:key1');
    print('redis.get("dox:key1") = $doxKey1Val');

    final fooVal = await redis.get('foo');
    print('redis.get("foo") = $fooVal');

    final doxFooVal = await redis.get('dox:foo');
    print('redis.get("dox:foo") = $doxFooVal');
  } finally {
    await redis.disconnect();
    await localRedis.disconnect();
  }
}
