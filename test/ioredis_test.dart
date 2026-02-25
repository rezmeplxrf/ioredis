// ignore_for_file: use_is_even_rather_than_modulo, use_raw_strings

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

// docker run -d --name redis -p 6379:6379 redis:8.6.1-alpine

void main() {
  group('Redis |', () {
    late final Redis redis;
    final redisHost = Platform.environment['REDIS_HOST'] ?? '127.0.0.1';
    final redisPort =
        int.tryParse(Platform.environment['REDIS_PORT'] ?? '') ?? 6379;
    final redisPassword = Platform.environment['REDIS_PASSWORD'];
    final redisDb =
        int.tryParse(Platform.environment['REDIS_DB_IOREDIS'] ?? '') ?? 10;
    final commonOptions = RedisOptions(
      host: redisHost,
      port: redisPort,
      password:
          redisPassword == null || redisPassword.isEmpty ? null : redisPassword,
      db: redisDb,
    );
    setUpAll(() async {
      redis = Redis(commonOptions);
    });
    tearDownAll(() async {
      await redis.disconnect();
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
      final db2 = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: 2,
      ));

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

    test('cluster key slot uses hash tags', () async {
      final slotA = redis.keySlot('user:{42}:profile');
      final slotB = redis.keySlot('orders:{42}:recent');
      final slotC = redis.keySlot('orders:{43}:recent');

      expect(slotA, equals(slotB));
      expect(slotA, isNot(equals(slotC)));
      expect(slotA, inInclusiveRange(0, 16383));
    });

    test('cluster diagnostics exposes cache state', () {
      final diagnostics = redis.clusterDiagnostics();
      expect(diagnostics.enabled, equals(commonOptions.enableClusterMode));
      expect(diagnostics.knownSlotCount, greaterThanOrEqualTo(0));
      expect(diagnostics.knownNodeEndpoints, isA<List<String>>());
    });

    test('command events are emitted via onEvent', () async {
      final events = <RedisEvent>[];
      final observed = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        onEvent: events.add,
      ));
      addTearDown(() async {
        await observed.disconnect();
      });

      await observed.set('event:hook:key', 'ok');
      final value = await observed.get('event:hook:key');
      expect(value, equals('ok'));
      expect(
        events.any((e) => e.type == RedisEventType.commandSuccess),
        isTrue,
      );
    });

    test('sentinel refresh validates required configuration', () async {
      final sentinel = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        enableSentinelMode: true,
      ));
      addTearDown(() async {
        await sentinel.disconnect();
      });

      await expectLater(
        sentinel.refreshSentinelMaster(),
        throwsA(isA<RedisProtocolError>()),
      );
    });

    test('warmClusterSlots is safe when cluster mode disabled', () async {
      final nonCluster = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
      ));
      addTearDown(() async {
        await nonCluster.disconnect();
      });

      final warmed = await nonCluster.warmClusterSlots();
      expect(warmed, isFalse);
      final diagnostics = nonCluster.clusterDiagnostics();
      expect(diagnostics.knownSlotCount, equals(0));
      expect(diagnostics.lastRefreshedAt, isNull);
    });

    test('cluster mode enforces same-slot for multi-key commands', () async {
      final clusterLike = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        enableClusterMode: true,
      ));
      addTearDown(() async {
        await clusterLike.disconnect();
      });

      await expectLater(
        clusterLike.sendCommand(<String>[
          'MGET',
          'user:{1}:a',
          'user:{2}:b',
        ]),
        throwsA(isA<RedisProtocolError>()),
      );

      await clusterLike.set('user:{42}:a', 'x');
      await clusterLike.set('user:{42}:b', 'y');
      final values =
          await clusterLike.mget(<String>['user:{42}:a', 'user:{42}:b']);
      expect(values, equals(<String?>['x', 'y']));
    });

    test('protocolVersion 3 connection works', () async {
      final resp3 = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        protocolVersion: 3,
      ));
      addTearDown(() async {
        await resp3.disconnect();
      });

      try {
        await resp3.set('resp3:key', 'ok');
        expect(await resp3.get('resp3:key'), equals('ok'));
      } catch (e) {
        final upper = e.toString().toUpperCase();
        if (upper.contains('UNKNOWN COMMAND') && upper.contains('HELLO')) {
          return;
        }
        rethrow;
      }
    });

    test('pub/sub', () async {
      final sub = Redis(commonOptions);
      addTearDown(() async {
        await sub.disconnect();
      });

      final chat1 = Completer<String?>();
      final subscriber1 = await sub.subscribe('chat1');
      subscriber1.onMessage = (channel, message) {
        if (channel == 'chat1' && !chat1.isCompleted) {
          chat1.complete(message);
        }
      };

      final chat2 = Completer<String?>();
      final subscriber2 = await sub.subscribe('chat2');
      subscriber2.onMessage = (channel, message) {
        if (channel == 'chat2' && !chat2.isCompleted) {
          chat2.complete(message);
        }
      };

      final pub = sub.duplicate();
      addTearDown(() async {
        await pub.disconnect();
      });
      await pub.publish('chat1', 'hi');
      await pub.publish('chat2', 'hello');

      expect(await chat1.future.timeout(const Duration(seconds: 2)), 'hi');
      expect(await chat2.future.timeout(const Duration(seconds: 2)), 'hello');
    });

    test('publish does not lock client into publisher mode', () async {
      final client = Redis(commonOptions);
      addTearDown(() async {
        await client.disconnect();
      });

      await client.publish('mode_check_room', 'ping');
      final subscriber = await client.subscribe('mode_check_room');
      expect(subscriber.channel, equals('mode_check_room'));
      await client.unsubscribe('mode_check_room');
    });

    test('resubscribes active listeners after reconnect', () async {
      final reconnectOptions = RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        onError: (_) {},
      );
      final sub = Redis(reconnectOptions);
      final killer = sub.duplicate();
      final pub = sub.duplicate();
      addTearDown(() async {
        await sub.disconnect();
        await killer.disconnect();
        await pub.disconnect();
      });

      final clientIdRaw = await sub.sendCommand(<String>['CLIENT', 'ID']);
      final clientId =
          clientIdRaw is int ? clientIdRaw : int.parse(clientIdRaw.toString());

      final received = Completer<String?>();
      final listener = await sub.subscribe('reconnect_room');
      listener.onMessage = (channel, message) {
        if (channel == 'reconnect_room' && !received.isCompleted) {
          received.complete(message);
        }
      };

      await killer.sendCommand(<String>[
        'CLIENT',
        'KILL',
        'ID',
        clientId.toString(),
      ]);

      for (var i = 0; i < 10 && !received.isCompleted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await pub.publish('reconnect_room', 'after_reconnect');
      }

      expect(
        await received.future.timeout(const Duration(seconds: 4)),
        equals('after_reconnect'),
      );
    });

    test('packet handling errors are routed to onError', () async {
      final errors = <dynamic>[];
      final sub = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        onError: errors.add,
      ));
      final pub = sub.duplicate();
      addTearDown(() async {
        await sub.disconnect();
        await pub.disconnect();
      });

      final listener = await sub.subscribe('error_hook_room');
      listener.onMessage = (channel, message) {
        throw StateError('handler-failure');
      };

      await pub.publish('error_hook_room', 'boom');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(errors, isNotEmpty);
      expect(errors.any((e) => e is RedisProtocolError), isTrue);
    });

    test('unsubscribe API cleans listener', () async {
      final sub = Redis(commonOptions);
      addTearDown(() async {
        await sub.disconnect();
      });

      final listener = await sub.subscribe('cleanup_room');
      final received = Completer<String?>();
      listener.onMessage = (channel, message) {
        if (channel == 'cleanup_room' && !received.isCompleted) {
          received.complete(message);
        }
      };

      await sub.unsubscribe('cleanup_room');
      expect(sub.connection.subscribeListeners, isEmpty);

      final pub = sub.duplicate();
      addTearDown(() async {
        await pub.disconnect();
      });
      await pub.publish('cleanup_room', 'should_not_arrive');

      await expectLater(
        received.future.timeout(const Duration(milliseconds: 250)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('explicit command timeout throws RedisTimeoutError', () async {
      final timeoutRedis = Redis(commonOptions);
      addTearDown(() async {
        await timeoutRedis.disconnect();
      });

      await expectLater(
        timeoutRedis.sendCommand(
          <String>['BLPOP', 'timeout_never_key', '0'],
          timeout: const Duration(milliseconds: 120),
        ),
        throwsA(isA<RedisTimeoutError>()),
      );

      await timeoutRedis.set('timeout_recovered', 'ok');
      expect(await timeoutRedis.get('timeout_recovered'), 'ok');
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

    // Array and List Tests
    test('MGET with empty list', () async {
      final res = await redis.mget(<String>[]);
      expect(res, isEmpty);
    });

    test('MDELETE with empty list is no-op', () async {
      await redis.set('mdelete_empty_guard', 'alive');
      await redis.mdelete(<String>[]);
      final value = await redis.get('mdelete_empty_guard');
      expect(value, equals('alive'));
    });

    test('MGET with single non-existent key', () async {
      final res = await redis.mget(<String>['nonexistent_single']);
      expect(res.length, equals(1));
      expect(res.first, isNull);
    });

    test('MGET with single existing key', () async {
      await redis.set('single_exists', 'single_value');
      final res = await redis.mget(<String>['single_exists']);
      expect(res.length, equals(1));
      expect(res.first, equals('single_value'));
    });

    test('MGET with large number of keys', () async {
      // Set up test data
      final keys = <String>[];
      final expectedValues = <String>[];

      for (var i = 0; i < 100; i++) {
        final key = 'bulk_key_$i';
        final value = 'bulk_value_$i';
        keys.add(key);
        expectedValues.add(value);
        await redis.set(key, value);
      }

      final res = await redis.mget(keys);
      expect(res, equals(expectedValues));
    });

    test('MDELETE with multiple keys', () async {
      // Set up test data
      await redis.set('delete1', 'value1');
      await redis.set('delete2', 'value2');
      await redis.set('delete3', 'value3');

      // Delete multiple keys
      await redis.mdelete(['delete1', 'delete2', 'delete3']);

      // Verify they're deleted
      final res = await redis.mget(['delete1', 'delete2', 'delete3']);
      expect(res, equals([null, null, null]));
    });

    // Large Value Tests
    test('large string value (1MB)', () async {
      final largeValue = 'x' * 1024 * 1024; // 1MB string
      await redis.set('large_key', largeValue);
      final retrievedValue = await redis.get('large_key');
      expect(retrievedValue, equals(largeValue));
    });

    test('very large string value (10MB)', () async {
      final veryLargeValue = 'a' * 10 * 1024 * 1024; // 10MB string
      await redis.set('very_large_key', veryLargeValue);
      final retrievedValue = await redis.get('very_large_key');
      expect(retrievedValue, equals(veryLargeValue));
    });

    test('binary-like data with null bytes', () async {
      const binaryData = 'Hello\x00World\x00\x01\x02\x03\xFF';
      await redis.set('binary_key', binaryData);
      final retrievedValue = await redis.get('binary_key');
      expect(retrievedValue, equals(binaryData));
    });

    // Edge Cases
    test('empty string value', () async {
      await redis.set('empty_key', '');
      final retrievedValue = await redis.get('empty_key');
      expect(retrievedValue, equals(''));
    });

    test('whitespace-only value', () async {
      const whitespaceValue = '   \t\n\r   ';
      await redis.set('whitespace_key', whitespaceValue);
      final retrievedValue = await redis.get('whitespace_key');
      expect(retrievedValue, equals(whitespaceValue));
    });

    test('special characters in key', () async {
      const specialKey = 'key:with:colons-and-dashes_and_underscores.and.dots';
      await redis.set(specialKey, 'special_value');
      final retrievedValue = await redis.get(specialKey);
      expect(retrievedValue, equals('special_value'));
    });

    test('unicode and emoji values', () async {
      const unicodeValue = '🚀 Hello 世界 🌍 Émojis & Ünïcødé 👨‍💻';
      await redis.set('unicode_key', unicodeValue);
      final retrievedValue = await redis.get('unicode_key');
      expect(retrievedValue, equals(unicodeValue));
    });

    test('very long key name', () async {
      final longKey = 'x' * 1000; // 1000 character key
      await redis.set(longKey, 'long_key_value');
      final retrievedValue = await redis.get(longKey);
      expect(retrievedValue, equals('long_key_value'));
    });

    test('JSON string values', () async {
      const jsonValue =
          '{"name": "John", "age": 30, "city": "New York", "active": true, "scores": [85, 92, 78]}';
      await redis.set('json_key', jsonValue);
      final retrievedValue = await redis.get('json_key');
      expect(retrievedValue, equals(jsonValue));
    });

    test('newline characters in value', () async {
      const multilineValue = 'Line 1\nLine 2\r\nLine 3\n\nLine 5';
      await redis.set('multiline_key', multilineValue);
      final retrievedValue = await redis.get('multiline_key');
      expect(retrievedValue, equals(multilineValue));
    });

    test('setting and getting null key handling', () async {
      // Test getting a key that was never set
      final nonExistentValue = await redis.get('never_set_key');
      expect(nonExistentValue, isNull);
    });

    test('overwriting existing key', () async {
      await redis.set('overwrite_key', 'original_value');
      await redis.set('overwrite_key', 'new_value');
      final retrievedValue = await redis.get('overwrite_key');
      expect(retrievedValue, equals('new_value'));
    });

    test('setting key with expiry then overwriting without expiry', () async {
      // Set with expiry
      await redis.set('expiry_key', 'expires', 'EX', 10);

      // Overwrite without expiry
      await redis.set('expiry_key', 'permanent');

      // Wait longer than original expiry would have been
      await Future<void>.delayed(const Duration(seconds: 1));

      final retrievedValue = await redis.get('expiry_key');
      expect(retrievedValue, equals('permanent'));
    });

    test('concurrent operations on same key', () async {
      final futures = <Future<void>>[];

      // Perform concurrent sets
      for (var i = 0; i < 10; i++) {
        futures.add(redis.set('concurrent_key', 'value_$i'));
      }

      await Future.wait(futures);

      // The key should have some value (exact value depends on timing)
      final finalValue = await redis.get('concurrent_key');
      expect(finalValue, isNotNull);
      expect(finalValue!.startsWith('value_'), isTrue);
    });

    test('stress test - many keys rapidly', () async {
      final futures = <Future<void>>[];

      // Set many keys rapidly
      for (var i = 0; i < 50; i++) {
        futures.add(redis.set('stress_key_$i', 'stress_value_$i'));
      }

      await Future.wait(futures);

      // Verify a few random keys
      final value10 = await redis.get('stress_key_10');
      final value25 = await redis.get('stress_key_25');
      final value40 = await redis.get('stress_key_40');

      expect(value10, equals('stress_value_10'));
      expect(value25, equals('stress_value_25'));
      expect(value40, equals('stress_value_40'));
    });

    test('delete and mdelete edge cases', () async {
      // Test deleting non-existent key (should not throw)
      await redis.delete('non_existent_key');

      // Test multiple delete with mix of existing and non-existing
      await redis.set('exists_for_delete', 'value');
      await redis
          .mdelete(['exists_for_delete', 'non_existent_1', 'non_existent_2']);

      final deletedValue = await redis.get('exists_for_delete');
      expect(deletedValue, isNull);
    });

    test('multi supports chaining and does not replay commands', () async {
      final tx = redis.multi()
        ..set('mkey1', 'v1')
        ..set('mkey2', 'v2')
        ..get('mkey1')
        ..get('mkey2');
      final first = await tx.exec();
      expect(first.length, equals(4));
      expect(first[2], equals('v1'));
      expect(first[3], equals('v2'));

      final second = await tx.exec();
      expect(second, isEmpty);
    });

    test('multi discards transaction when queueing fails', () async {
      final tx = redis.multi()
        ..set('discard_key', 'v1')
        ..command(<String>['NOT_A_REDIS_COMMAND'])
        ..set('discard_key', 'v2');

      await expectLater(
        tx.exec(),
        throwsA(isA<RedisCommandError>()),
      );

      await redis.set('post_discard_key', 'ok');
      expect(await redis.get('post_discard_key'), equals('ok'));
    });

    test('pipeline batches writes and keeps response order', () async {
      final result = redis.pipeline()
        ..set('pipe_k1', 'v1')
        ..set('pipe_k2', 'v2')
        ..get('pipe_k1')
        ..get('pipe_k2');
      final values = await result.exec();
      expect(values[0], 'OK');
      expect(values[1], 'OK');
      expect(values[2], 'v1');
      expect(values[3], 'v2');
    });

    test('pipeline respects key prefix exactly once', () async {
      final prefixed = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        keyPrefix: 'pipepref',
      ));
      addTearDown(() async {
        await prefixed.disconnect();
      });

      await (prefixed.pipeline()
            ..set('k1', 'v1')
            ..get('k1'))
          .exec();

      expect(await redis.get('pipepref:k1'), 'v1');
      expect(await redis.get('pipepref:pipepref:k1'), isNull);
    });

    test('pipeline supports explicit batch size and preserves order', () async {
      final result = await (redis.pipeline()
            ..set('pipe_batch_k1', 'v1')
            ..set('pipe_batch_k2', 'v2')
            ..set('pipe_batch_k3', 'v3')
            ..get('pipe_batch_k1')
            ..get('pipe_batch_k2')
            ..get('pipe_batch_k3'))
          .exec(batchSize: 2);

      expect(result, equals(<dynamic>['OK', 'OK', 'OK', 'v1', 'v2', 'v3']));
    });

    test('pipeline enforces maxPendingCommands backpressure', () async {
      final constrained = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        maxPendingCommands: 2,
      ));
      addTearDown(() async {
        await constrained.disconnect();
      });

      await expectLater(
        constrained.sendPipeline(<List<String>>[
          <String>['SET', 'bp:k1', '1'],
          <String>['SET', 'bp:k2', '2'],
          <String>['SET', 'bp:k3', '3'],
        ]),
        throwsA(isA<RedisConnectionError>()),
      );
    });

    test('retry policy honors max attempts', () async {
      var retriesInvoked = 0;
      final retryPolicy = RedisRetryPolicy(
        maxAttempts: 3,
        initialDelay: Duration.zero,
        maxDelay: Duration.zero,
        shouldRetry: (error, attempt, command) {
          retriesInvoked++;
          return true;
        },
      );

      await expectLater(
        redis.sendCommand(
          <String>['DOES_NOT_EXIST_COMMAND'],
          retryPolicy: retryPolicy,
        ),
        throwsA(isA<RedisCommandError>()),
      );
      expect(retriesInvoked, 2);
    });

    test('core data-structure command wrappers', () async {
      final ns = DateTime.now().microsecondsSinceEpoch;
      final hashKey = 'p2:$ns:hash';
      final listKey = 'p2:$ns:list';
      final setKey = 'p2:$ns:set';
      final zsetKey = 'p2:$ns:zset';

      await redis.hset(hashKey, 'f1', 'v1');
      await redis.hset(hashKey, 'f2', 'v2');
      expect(await redis.hget(hashKey, 'f1'), equals('v1'));
      expect(
        await redis.hmget(hashKey, <String>['f1', 'f2', 'f3']),
        equals(<String?>['v1', 'v2', null]),
      );

      expect(await redis.lpush(listKey, <String>['a', 'b']), equals(2));
      expect(await redis.rpush(listKey, <String>['c']), equals(3));
      expect(
          await redis.lrange(listKey, 0, -1), equals(<String>['b', 'a', 'c']));

      expect(await redis.sadd(setKey, <String>['x', 'y', 'x']), equals(2));
      final members = await redis.smembers(setKey);
      expect(members.toSet(), equals(<String>{'x', 'y'}));

      await redis.zadd(zsetKey, 1.5, 'm1');
      await redis.zadd(zsetKey, 2.5, 'm2');
      expect(
        await redis.zrange(zsetKey, 0, -1, withScores: true),
        equals(<String>['m1', '1.5', 'm2', '2.5']),
      );
    });

    test('scriptLoad and evalsha with NOSCRIPT reload fallback', () async {
      const script = 'return ARGV[1]';
      final sha = await redis.scriptLoad(script);
      final direct = await redis.evalsha(sha, args: <dynamic>['ok']);
      expect(direct, equals('ok'));

      final fallback = await redis.evalsha(
        'ffffffffffffffffffffffffffffffffffffffff',
        args: <dynamic>['fallback'],
        reloadOnNoScript: true,
        scriptOnNoScript: script,
      );
      expect(fallback, equals('fallback'));
    });

    test('scan iterators return expected values', () async {
      for (var i = 0; i < 5; i++) {
        await redis.set('p2:scan:key:$i', 'v$i');
      }
      final keys =
          await redis.scanIterator(match: 'p2:scan:key:*', count: 2).toList();
      expect(
          keys.toSet(),
          equals(<String>{
            'p2:scan:key:0',
            'p2:scan:key:1',
            'p2:scan:key:2',
            'p2:scan:key:3',
            'p2:scan:key:4',
          }));

      await redis.hset('p2:scan:hash', 'a', '1');
      await redis.hset('p2:scan:hash', 'b', '2');
      final hPairs =
          await redis.hscanIterator('p2:scan:hash', count: 1).toList();
      final hMap = Map<String, String>.fromEntries(hPairs);
      expect(hMap['a'], equals('1'));
      expect(hMap['b'], equals('2'));

      await redis.sadd('p2:scan:set', <String>['s1', 's2']);
      final sMembers =
          await redis.sscanIterator('p2:scan:set', count: 1).toList();
      expect(sMembers.toSet(), equals(<String>{'s1', 's2'}));

      await redis.zadd('p2:scan:zset', 1, 'z1');
      await redis.zadd('p2:scan:zset', 2, 'z2');
      final zPairs =
          await redis.zscanIterator('p2:scan:zset', count: 1).toList();
      final zMap = Map<String, double>.fromEntries(zPairs);
      expect(zMap['z1'], equals(1));
      expect(zMap['z2'], equals(2));
    });

    test('xadd and xrange wrappers', () async {
      final id = await redis.xadd('p2:stream', '*', <String, String>{
        'field1': 'value1',
        'field2': 'value2',
      });
      expect(id, contains('-'));

      final rows = await redis.xrange('p2:stream', '-', '+', count: 10);
      expect(rows, isNotEmpty);
      expect(rows.first, isA<List<dynamic>>());
    });

    test('sharded pub/sub works when supported', () async {
      final sub = Redis(commonOptions);
      final pub = sub.duplicate();
      addTearDown(() async {
        await sub.disconnect();
        await pub.disconnect();
      });

      try {
        final received = Completer<String?>();
        final listener = await sub.ssubscribe('p2:shard:room');
        listener.onMessage = (channel, message) {
          if (channel == 'p2:shard:room' && !received.isCompleted) {
            received.complete(message);
          }
        };

        await pub.spublish('p2:shard:room', 'hello-shard');
        expect(
          await received.future.timeout(const Duration(seconds: 2)),
          equals('hello-shard'),
        );
        await sub.sunsubscribe('p2:shard:room');
      } catch (e) {
        if (_isUnknownCommand(e, 'SSUBSCRIBE') ||
            _isUnknownCommand(e, 'SPUBLISH')) {
          return;
        }
        rethrow;
      }
    });

    test('special Redis protocol characters in values', () async {
      // Test values that contain Redis protocol special characters
      final specialValues = [
        '+OK\r\n',
        '-ERR\r\n',
        ':123\r\n',
        '\$5\r\nhello\r\n',
        '*2\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n',
      ];

      for (var i = 0; i < specialValues.length; i++) {
        final key = 'special_protocol_$i';
        final value = specialValues[i];
        await redis.set(key, value);
        final retrieved = await redis.get(key);
        expect(retrieved, equals(value));
      }
    });

    test('integer replies are parsed as int', () async {
      await redis.set('int_reply_key', '41');
      final value = await redis.sendCommand(<String>['INCR', 'int_reply_key']);
      expect(value, isA<int>());
      expect(value, equals(42));
    });

    test('setBuffer/getBuffer supports binary payloads', () async {
      final payload = Uint8List.fromList(<int>[
        0,
        1,
        2,
        3,
        255,
        254,
        128,
        64,
        10,
        13,
        0,
      ]);
      await redis.setBuffer('buffer_key', payload);
      final received = await redis.getBuffer('buffer_key');
      expect(received, isNotNull);
      expect(received, equals(payload));
    });

    test('getBuffer roundtrips invalid UTF-8 bytes', () async {
      final payload = Uint8List.fromList(<int>[
        0xF0,
        0x28,
        0x8C,
        0x28,
      ]);
      await redis.setBuffer('invalid_utf8_key', payload);
      final bytes = await redis.getBuffer('invalid_utf8_key');
      expect(bytes, equals(payload));
      await expectLater(
        redis.get('invalid_utf8_key'),
        throwsA(
          isA<RedisConnectionError>().having(
            (e) => e.cause,
            'cause',
            isA<FormatException>(),
          ),
        ),
      );
    });

    test('setBuffer/getBuffer roundtrips random binary corpus', () async {
      final payload =
          Uint8List.fromList(List<int>.generate(512, (i) => (i * 73) % 256));
      await redis.setBuffer('buffer_random_corpus', payload);
      final received = await redis.getBuffer('buffer_random_corpus');
      expect(received, equals(payload));
    });

    test('cluster mode checks script keys are same slot', () async {
      final clusterLike = Redis(RedisOptions(
        host: commonOptions.host,
        port: commonOptions.port,
        password: commonOptions.password,
        db: commonOptions.db,
        enableClusterMode: true,
      ));
      addTearDown(() async {
        await clusterLike.disconnect();
      });

      await expectLater(
        clusterLike.eval(
          'return 1',
          keys: <String>['k:{1}', 'k:{2}'],
        ),
        throwsA(isA<RedisProtocolError>()),
      );
    });

    // JSON Tests (if RedisJSON module is available)
    group('JSON operations |', () {
      test('JSON set and get basic object', () async {
        final jsonData = {'name': 'John', 'age': 30, 'city': 'New York'};

        try {
          await redis.jsonSet('user:1', '.', jsonData);
          final retrieved = await redis.jsonGet('user:1', '.');
          expect(retrieved, isNotNull);
          // The retrieved JSON should be a string representation
          expect(retrieved, contains('John'));
          expect(retrieved, contains('30'));
          expect(retrieved, contains('New York'));
        } catch (e) {
          // Skip JSON tests if RedisJSON module is not available
          if (_isRedisJsonUnavailable(e)) return;
          rethrow;
        }
      });

      test('JSON set and get nested object', () async {
        final complexJson = {
          'user': {
            'personal': {'name': 'Alice', 'age': 25},
            'preferences': {'theme': 'dark', 'notifications': true}
          },
          'metadata': {'created': '2023-01-01', 'version': '1.0'}
        };

        try {
          await redis.jsonSet('complex:1', '.', complexJson);

          // Get full object
          final fullObject = await redis.jsonGet('complex:1', '.');
          expect(fullObject, isNotNull);

          // Get nested values
          final userName =
              await redis.jsonGet('complex:1', '.user.personal.name');
          expect(userName, contains('Alice'));

          final userAge =
              await redis.jsonGet('complex:1', '.user.personal.age');
          expect(userAge, contains('25'));
        } catch (e) {
          if (_isRedisJsonUnavailable(e)) return;
          rethrow;
        }
      });

      test('JSON array operations', () async {
        final arrayData = {
          'fruits': ['apple', 'banana', 'orange'],
          'numbers': [1, 2, 3, 4, 5],
          'mixed': ['text', 42, true, null]
        };

        try {
          await redis.jsonSet('arrays:1', '.', arrayData);

          final retrieved = await redis.jsonGet('arrays:1', '.');
          expect(retrieved, isNotNull);
          expect(retrieved, contains('apple'));
          expect(retrieved, contains('banana'));
          expect(retrieved, contains('orange'));
        } catch (e) {
          if (_isRedisJsonUnavailable(e)) return;
          rethrow;
        }
      });

      test('JSON with special characters and unicode', () async {
        final unicodeJson = {
          'message': '🚀 Hello 世界 🌍',
          'symbols': '!@#\$%^&*()_+-=[]{}|;:,.<>?',
          'quotes': 'He said "Hello" and she said \'Hi\'',
          'newlines': 'Line 1\nLine 2\r\nLine 3'
        };

        try {
          await redis.jsonSet('unicode:1', '.', unicodeJson);
          final retrieved = await redis.jsonGet('unicode:1', '.');
          expect(retrieved, isNotNull);
          expect(retrieved, contains('🚀'));
          expect(retrieved, contains('世界'));
        } catch (e) {
          if (_isRedisJsonUnavailable(e)) return;
          rethrow;
        }
      });

      test('JSON large object', () async {
        // Create a large JSON object
        final largeJson = <String, dynamic>{};
        for (var i = 0; i < 1000; i++) {
          largeJson['key_$i'] = {
            'index': i,
            'value': 'value_$i',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'metadata': {
              'processed': i % 2 == 0,
              'category': 'category_${i % 10}',
              'tags': ['tag_${i % 5}', 'tag_${i % 7}']
            }
          };
        }

        try {
          await redis.jsonSet('large:1', '.', largeJson);
          final retrieved = await redis.jsonGet('large:1', '.');
          expect(retrieved, isNotNull);

          // Test accessing specific parts of the large object
          final specificKey = await redis.jsonGet('large:1', '.key_500');
          expect(specificKey, isNotNull);
          expect(specificKey, contains('value_500'));
        } catch (e) {
          if (_isRedisJsonUnavailable(e)) return;
          rethrow;
        }
      });

      test('JSON key prefix is applied', () async {
        final prefixed = Redis(RedisOptions(
          host: commonOptions.host,
          port: commonOptions.port,
          password: commonOptions.password,
          db: commonOptions.db,
          keyPrefix: 'jsonpref',
        ));
        addTearDown(() async {
          await prefixed.disconnect();
        });

        try {
          await prefixed.jsonSet('k1', '.', {'ok': true});
          final raw = await redis.jsonGet('jsonpref:k1', '.');
          expect(raw, isNotNull);
          expect(raw, contains('ok'));
        } catch (e) {
          if (_isRedisJsonUnavailable(e)) return;
          rethrow;
        }
      });
    });
  });
}

bool _isRedisJsonUnavailable(Object error) {
  final message = error.toString().toUpperCase();
  return message.contains('UNKNOWN COMMAND') && message.contains('JSON.');
}

bool _isUnknownCommand(Object error, String command) {
  final message = error.toString().toUpperCase();
  return message.contains('UNKNOWN COMMAND') && message.contains(command);
}
