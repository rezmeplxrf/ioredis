// ignore_for_file: avoid_redundant_argument_values

import 'package:ioredis/ioredis.dart';

void main() async {
  // Create Redis connection
  final redis = Redis(RedisOptions(
    host: '127.0.0.1',
    port: 6379,
    // password: 'your_password', // uncomment if needed
    // db: 0, // optional, default database
  ));

  try {
    print('=== Basic Operations ===');

    // Set a value
    await redis.set('user:1:name', 'John Doe');
    print('✅ Set user:1:name = John Doe');

    // Get a value
    final name = await redis.get('user:1:name');
    print('📖 Get user:1:name = $name');

    // Set with expiration
    await redis.set('session:abc', 'user123', 'EX', 30);
    print('✅ Set session:abc with 30s expiration');

    print('\n=== Bulk Operations ===');

    // Set multiple values
    await redis.set('key1', 'value1');
    await redis.set('key2', 'value2');
    await redis.set('key3', 'value3');
    print('✅ Set multiple keys');

    // Get multiple values (MGET)
    final values = await redis.mget(['key1', 'key2', 'key3', 'non_existent']);
    print('📖 MGET result: $values');

    // Empty MGET test
    final emptyResult = await redis.mget([]);
    print('📖 Empty MGET result: $emptyResult');

    print('\n=== Unicode and Special Characters ===');

    // Unicode support
    await redis.set('greeting', 'မင်္ဂလာပါ'); // Burmese
    await redis.set('emoji', '🚀 Hello 世界 🌍 Émojis & Ünïcødé 👨‍💻');

    final greeting = await redis.get('greeting');
    final emoji = await redis.get('emoji');
    print('📖 Unicode: $greeting');
    print('📖 Emoji: $emoji');

    print('\n=== JSON Operations (if RedisJSON available) ===');

    try {
      final userData = {
        'name': 'Alice',
        'age': 30,
        'preferences': {'theme': 'dark', 'notifications': true}
      };

      await redis.jsonSet('user:2', '.', userData);
      final jsonResult = await redis.jsonGet('user:2', '.');
      print('📖 JSON document: $jsonResult');

      final userName = await redis.jsonGet('user:2', '.name');
      print('📖 JSON name field: $userName');
    } catch (e) {
      print(
          '⚠️ JSON operations not available (RedisJSON module not installed)');
    }

    print('\n=== Cleanup ===');

    // Delete multiple keys
    await redis
        .mdelete(['key1', 'key2', 'key3', 'user:1:name', 'greeting', 'emoji']);
    print('✅ Cleaned up test keys');

    print('\n🎉 Example completed successfully!');
  } catch (e) {
    print('❌ Error: $e');
  } finally {
    // Always disconnect when done
    await redis.disconnect();
    print('🔌 Disconnected from Redis');
  }
}
