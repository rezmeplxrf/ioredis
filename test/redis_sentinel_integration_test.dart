import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

final _runSentinelIntegration =
    Platform.environment['REDIS_SENTINEL_INTEGRATION'] == '1';

void main() {
  group(
    'Redis sentinel integration |',
    skip: !_runSentinelIntegration,
    () {
      final sentinelHost =
          Platform.environment['REDIS_SENTINEL_HOST'] ?? '127.0.0.1';
      final sentinelPort =
          int.tryParse(Platform.environment['REDIS_SENTINEL_PORT'] ?? '') ??
              26379;
      final masterName =
          Platform.environment['REDIS_SENTINEL_MASTER'] ?? 'mymaster';
      final password = Platform.environment['REDIS_PASSWORD'];

      test('refreshSentinelMaster resolves master and auto-routes commands',
          () async {
        final sentinelQuery = Redis(RedisOptions(
          host: sentinelHost,
          port: sentinelPort,
          password: password == null || password.isEmpty ? null : password,
        ));
        addTearDown(() async {
          await sentinelQuery.disconnect();
        });

        final expectedRaw = await sentinelQuery.sendCommand(<String>[
          'SENTINEL',
          'get-master-addr-by-name',
          masterName,
        ]);
        expect(expectedRaw, isA<List<dynamic>>());
        final expected = expectedRaw as List<dynamic>;
        expect(expected.length, greaterThanOrEqualTo(2));
        final expectedHost = expected[0] as String;
        final expectedPort = int.parse(expected[1].toString());

        final events = <RedisEventType>[];
        final redis = Redis(RedisOptions(
          port: 1, // intentionally wrong: should be replaced by sentinel.
          password: password == null || password.isEmpty ? null : password,
          enableSentinelMode: true,
          sentinelMasterName: masterName,
          sentinels: <RedisSentinelNode>[
            RedisSentinelNode(host: sentinelHost, port: sentinelPort),
          ],
          onEvent: (event) => events.add(event.type),
        ));
        addTearDown(() async {
          await redis.disconnect();
        });

        final resolved = await redis.refreshSentinelMaster();
        expect(resolved, isTrue);
        expect(redis.option.host, equals(expectedHost));
        expect(redis.option.port, equals(expectedPort));
        expect(redis.sentinelLastResolvedAt(), isNotNull);
        expect(events, contains(RedisEventType.sentinelResolveStart));
        expect(events, contains(RedisEventType.sentinelResolveSuccess));

        final key = 'sentinel:int:test:${DateTime.now().microsecondsSinceEpoch}';
        await redis.set(key, 'ok');
        final value = await redis.get(key);
        expect(value, equals('ok'));
      });
    },
  );
}
