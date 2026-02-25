import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('Redis eval |', () {
    late Redis redis;
    final redisHost = Platform.environment['REDIS_HOST'] ?? '127.0.0.1';
    final redisPort =
        int.tryParse(Platform.environment['REDIS_PORT'] ?? '') ?? 6379;
    final redisPassword = Platform.environment['REDIS_PASSWORD'];
    final redisDb =
        int.tryParse(Platform.environment['REDIS_DB_EVAL'] ?? '') ?? 12;

    setUpAll(() async {
      redis = Redis(
        RedisOptions(
          host: redisHost,
          port: redisPort,
          password: redisPassword == null || redisPassword.isEmpty
              ? null
              : redisPassword,
          db: redisDb,
        ),
      );
    });

    setUp(() async {
      await redis.flushdb();
    });

    tearDownAll(() async {
      await redis.disconnect();
    });

    test('evaluates script with keys and args', () async {
      final result = await redis.eval(
        'return {KEYS[1], ARGV[1], ARGV[2]}',
        keys: <String>['sample:key'],
        args: <dynamic>['a', 123],
      );

      expect(result, isA<List<dynamic>>());
      expect(result, equals(<dynamic>['sample:key', 'a', '123']));
    });

    test('applies key prefix for eval keys', () async {
      final prefixedRedis = Redis(
        RedisOptions(
          host: redisHost,
          port: redisPort,
          password: redisPassword == null || redisPassword.isEmpty
              ? null
              : redisPassword,
          db: redisDb,
          keyPrefix: 'pref',
        ),
      );
      addTearDown(() async {
        await prefixedRedis.disconnect();
      });

      await prefixedRedis.eval(
        "redis.call('SET', KEYS[1], ARGV[1]); return KEYS[1]",
        keys: <String>['k1'],
        args: <dynamic>['v1'],
      );

      final value = await redis.get('pref:k1');
      expect(value, equals('v1'));
    });

    test('supports atomic updates via eval under concurrency', () async {
      const script = '''
local count = redis.call('INCR', KEYS[1])
redis.call('EXPIRE', KEYS[1], tonumber(ARGV[1]))
return count
''';

      final operations = List<Future<dynamic>>.generate(
        25,
        (_) => redis.eval(
          script,
          keys: <String>['atomic:counter'],
          args: <dynamic>[60],
        ),
      );
      final results = await Future.wait(operations);

      final numericResults = results
          .map((e) => int.parse(e.toString()))
          .toList(growable: false)
        ..sort();

      expect(numericResults.first, equals(1));
      expect(numericResults.last, equals(25));

      final finalValue = await redis.get('atomic:counter');
      expect(finalValue, equals('25'));
    });
  });
}
