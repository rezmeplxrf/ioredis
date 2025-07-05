// ignore_for_file: avoid_redundant_argument_values

import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('Redis |', () {
    late final Redis redis;
    final commonOptions =
        RedisOptions(host: '127.0.0.1', port: 6379, password: 'pass');
    setUpAll(() async {
      redis = Redis(commonOptions);
    });
    tearDownAll(() async {
      await redis.disconnect();
      exit(0);
    });
    test('race request', () async {
      await redis.set('key1', 'redis1');
      await redis.set('key2', 'redis2');
      await redis.set('key3', 'redis3');

      final operations = <Future<dynamic>>[
        redis.get('key1'),
        redis.get('key2'),
        redis.get('key3'),
      ];

      final results = await Future.wait(operations);

      expect(results.first, 'redis1');
      expect(results.last, 'redis3');
      expect(results.length, 3);
    });

    test('keyPrefix', () async {
      final localRedis = Redis(RedisOptions(
          keyPrefix: 'dox', host: '127.0.0.1', port: 6379, password: 'pass'));

      await localRedis.set('foo', 'redis1');
      final s1 = await localRedis.get('key1');

      expect(s1, 'redis1');

      final redis2 =
          Redis(RedisOptions(host: '127.0.0.1', port: 6379, password: 'pass'));
      final s2 = await redis2.get('dox:foo');

      expect(s2, 'redis1');

      expect(s1, s2);

      await redis.delete('foo');

      final s3 = await redis2.get('dox:foo');

      expect(s3, null);
    });

    test('ut8f', () async {
      await redis.set('dox', 'မင်္ဂလာပါ');
      final data = await redis.get('dox');
      expect(data, 'မင်္ဂလာပါ');
    });

    test('custom socket', () async {
      final redis = Redis();
      redis.setSocket(await Socket.connect('127.0.0.1', 6379));
      await redis.set('dox', 'redis');
      final data = await redis.get('dox');
      expect(data, 'redis');
    });

    test('test', () async {
      await redis.set('dox', r'$Dox Framework');
      await redis.set('dox2', '*framework');

      final data1 = await redis.get('dox');
      final data2 = await redis.get('dox2');

      expect(data1, r'$Dox Framework');
      expect(data2, '*framework');
    });

    test('different db', () async {
      final db1 = Redis(commonOptions);
      final db2 = Redis(RedisOptions(port: commonOptions.port, db: 2));

      await db1.set('dox', 'value1');
      await db2.set('dox', 'value2');

      final data1 = await db1.get('dox');
      final data2 = await db2.get('dox');

      expect(true, data1 != data2);
    });

    test('duplicate', () async {
      final db2 = redis.duplicate();

      await redis.set('dox', 'value1');
      await db2.set('dox', 'value2');

      final data1 = await redis.get('dox');
      final data2 = await db2.get('dox');

      expect(data1, data2);
    });

    test('pub/sub', () async {
      final sub = Redis(commonOptions);

      final subscriber1 = await sub.subscribe('chat1');
      subscriber1.onMessage = (String channel, String? message) {
        print(channel);
        print(message);
      };

      final subscriber2 = await sub.subscribe('chat2');
      subscriber2.onMessage = (String channel, String? message) {
        print(channel);
        print(message);
      };

      final pub = sub.duplicate();
      await pub.publish('chat1', 'hi');
      await pub.publish('chat2', 'hello');

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    test('MGET', () async {
      await redis.set('A', '-AA');
      await redis.set('B', '+BB');
      await redis.set('C', 'CC');
      final res = await redis.mget(<String>['A', 'B', 'C', 'D']);
      expect(<String?>['-AA', '+BB', 'CC', null], res);
    });

    test('test expiry time', () async {
      await redis.set(
        'something',
        'Dox Framework',
        'EX',
        const Duration(seconds: 2).inSeconds,
      );

      await Future<void>.delayed(const Duration(seconds: 1));

      final data = await redis.get('something');

      expect(data, 'Dox Framework');

      await Future<void>.delayed(const Duration(seconds: 3));

      final data2 = await redis.get('something');

      expect(data2, null);
    });
  });
}
