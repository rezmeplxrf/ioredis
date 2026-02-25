import 'dart:io';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

final _runClusterIntegration =
    Platform.environment['REDIS_CLUSTER_INTEGRATION'] == '1';

class _ClusterSlotRange {
  const _ClusterSlotRange({
    required this.start,
    required this.end,
    required this.host,
    required this.port,
    required this.nodeId,
  });

  final int start;
  final int end;
  final String host;
  final int port;
  final String nodeId;
}

void main() {
  group(
    'Redis cluster integration |',
    skip: !_runClusterIntegration,
    () {
      final seedHost = Platform.environment['REDIS_CLUSTER_SEED_HOST'] ?? '127.0.0.1';
      final seedPort =
          int.tryParse(Platform.environment['REDIS_CLUSTER_SEED_PORT'] ?? '') ??
              7000;
      final redisPassword = Platform.environment['REDIS_PASSWORD'];
      final password =
          redisPassword == null || redisPassword.isEmpty ? null : redisPassword;

      Redis adminAt(String host, int port) {
        return Redis(RedisOptions(
          host: host,
          port: port,
          password: password,
        ));
      }

      test('handles MOVED after slot re-assignment with stale cache', () async {
        final cluster = Redis(RedisOptions(
          host: seedHost,
          port: seedPort,
          password: password,
          enableClusterMode: true,
          maxClusterRedirects: 8,
        ));
        addTearDown(() async {
          await cluster.disconnect();
        });

        final warmed = await cluster.warmClusterSlots();
        expect(warmed, isTrue);

        final slotsRaw =
            await cluster.sendCommand(<String>['CLUSTER', 'SLOTS']) as List<dynamic>;
        final ranges = _parseSlotRanges(slotsRaw);
        expect(ranges.length, greaterThanOrEqualTo(2));

        final source = ranges.first;
        final target = ranges.firstWhere(
          (r) => r.nodeId != source.nodeId,
          orElse: () => throw StateError('Need at least two master nodes'),
        );

        final sourceAdmin = adminAt(source.host, source.port);
        final targetAdmin = adminAt(target.host, target.port);
        addTearDown(() async {
          await sourceAdmin.disconnect();
          await targetAdmin.disconnect();
        });

        final slot = await _findEmptySlotInRange(sourceAdmin, source.start, source.end);
        expect(slot, isNotNull);
        final chosenSlot = slot!;
        final key = _findKeyForSlot(cluster, chosenSlot);

        // Ensure cache is warmed before changing slot ownership.
        await cluster.warmClusterSlots();

        try {
          await sourceAdmin.sendCommand(<String>[
            'CLUSTER',
            'SETSLOT',
            '$chosenSlot',
            'NODE',
            target.nodeId,
          ]);
          await targetAdmin.sendCommand(<String>[
            'CLUSTER',
            'SETSLOT',
            '$chosenSlot',
            'NODE',
            target.nodeId,
          ]);

          // Client has stale slot cache here; command should recover via MOVED.
          await cluster.set(key, 'moved-ok');
          final value = await cluster.get(key);
          expect(value, equals('moved-ok'));
        } finally {
          // Best-effort restore ownership to reduce impact on shared clusters.
          try {
            await sourceAdmin.sendCommand(<String>[
              'CLUSTER',
              'SETSLOT',
              '$chosenSlot',
              'NODE',
              source.nodeId,
            ]);
          } catch (_) {}
          try {
            await targetAdmin.sendCommand(<String>[
              'CLUSTER',
              'SETSLOT',
              '$chosenSlot',
              'NODE',
              source.nodeId,
            ]);
          } catch (_) {}
          try {
            await cluster.refreshClusterSlots();
          } catch (_) {}
        }
      });

      test('handles ASK redirect during migrating/importing slot state',
          () async {
        final cluster = Redis(RedisOptions(
          host: seedHost,
          port: seedPort,
          password: password,
          enableClusterMode: true,
          maxClusterRedirects: 8,
        ));
        addTearDown(() async {
          await cluster.disconnect();
        });

        final warmed = await cluster.warmClusterSlots();
        expect(warmed, isTrue);

        final slotsRaw =
            await cluster.sendCommand(<String>['CLUSTER', 'SLOTS']) as List<dynamic>;
        final ranges = _parseSlotRanges(slotsRaw);
        expect(ranges.length, greaterThanOrEqualTo(2));

        final source = ranges.first;
        final target = ranges.firstWhere(
          (r) => r.nodeId != source.nodeId,
          orElse: () => throw StateError('Need at least two master nodes'),
        );

        final sourceAdmin = adminAt(source.host, source.port);
        final targetAdmin = adminAt(target.host, target.port);
        addTearDown(() async {
          await sourceAdmin.disconnect();
          await targetAdmin.disconnect();
        });

        final slot = await _findEmptySlotInRange(sourceAdmin, source.start, source.end);
        expect(slot, isNotNull);
        final chosenSlot = slot!;
        final key = _findKeyForSlot(cluster, chosenSlot);

        try {
          await targetAdmin.sendCommand(<String>[
            'CLUSTER',
            'SETSLOT',
            '$chosenSlot',
            'IMPORTING',
            source.nodeId,
          ]);
          await sourceAdmin.sendCommand(<String>[
            'CLUSTER',
            'SETSLOT',
            '$chosenSlot',
            'MIGRATING',
            target.nodeId,
          ]);

          // Non-existing key on migrating source should trigger ASK redirect.
          await cluster.set(key, 'ask-ok');
          final value = await cluster.get(key);
          expect(value, equals('ask-ok'));
        } finally {
          // Normalize slot state back to source owner.
          try {
            await sourceAdmin.sendCommand(<String>[
              'CLUSTER',
              'SETSLOT',
              '$chosenSlot',
              'NODE',
              source.nodeId,
            ]);
          } catch (_) {}
          try {
            await targetAdmin.sendCommand(<String>[
              'CLUSTER',
              'SETSLOT',
              '$chosenSlot',
              'NODE',
              source.nodeId,
            ]);
          } catch (_) {}
          try {
            await cluster.refreshClusterSlots();
          } catch (_) {}
        }
      });
    },
  );
}

List<_ClusterSlotRange> _parseSlotRanges(List<dynamic> raw) {
  final out = <_ClusterSlotRange>[];
  for (final entry in raw) {
    if (entry is! List || entry.length < 3) continue;
    final start = entry[0];
    final end = entry[1];
    final primary = entry[2];
    if (start is! int || end is! int) continue;
    if (primary is! List || primary.length < 3) continue;
    final host = primary[0];
    final port = primary[1];
    final nodeId = primary[2];
    if (host is! String || port is! int || nodeId is! String) continue;
    out.add(_ClusterSlotRange(
      start: start,
      end: end,
      host: host,
      port: port,
      nodeId: nodeId,
    ));
  }
  return out;
}

Future<int?> _findEmptySlotInRange(Redis admin, int start, int end) async {
  for (var slot = start; slot <= end; slot++) {
    final keys = await admin.sendCommand(<String>[
      'CLUSTER',
      'GETKEYSINSLOT',
      '$slot',
      '1',
    ]);
    if (keys is List && keys.isEmpty) {
      return slot;
    }
  }
  return null;
}

String _findKeyForSlot(Redis redis, int slot) {
  for (var i = 0; i < 300000; i++) {
    final key = 'cluster:it:{s$i}';
    if (redis.keySlot(key) == slot) {
      return key;
    }
  }
  throw StateError('Unable to find key for slot $slot');
}
