import 'dart:async';
import 'dart:typed_data';

import 'package:ioredis/ioredis.dart';

Future<void> main() async {
  final redis = Redis(RedisOptions(
    host: '127.0.0.1',
    port: 6379,
    db: 0,
  ));

  final pub = redis.duplicate();
  final sub = redis.duplicate();

  try {
    await runBasicOps(redis);
    await runPipelineAndMulti(redis);
    await runWatchTransaction(redis);
    await runScanIterators(redis);
    await runBinaryOps(redis);
    await runPubSub(pub, sub);
    await runJsonOps(redis);
  } finally {
    await cleanup(redis);
    await pub.disconnect();
    await sub.disconnect();
    await redis.disconnect();
  }
}

Future<void> runBasicOps(Redis redis) async {
  print('\n== Basic SET/GET/MGET ==');
  await redis.set('example:user:1', 'alice');
  await redis.set('example:user:2', 'bob');

  final user1 = await redis.get('example:user:1');
  final users = await redis.mget(
    <String>['example:user:1', 'example:user:2', 'example:user:missing'],
  );

  print('example:user:1 => $user1');
  print('mget => $users');
}

Future<void> runPipelineAndMulti(Redis redis) async {
  print('\n== Pipeline and MULTI ==');

  final pipelineResult = await (redis.pipeline()
        ..set('example:pipe:1', 'v1')
        ..set('example:pipe:2', 'v2')
        ..get('example:pipe:1')
        ..get('example:pipe:2'))
      .exec(batchSize: 2);
  print('pipeline => $pipelineResult');

  final multiResult = await (redis.multi()
        ..set('example:tx:1', 't1')
        ..set('example:tx:2', 't2')
        ..get('example:tx:1')
        ..get('example:tx:2'))
      .exec();
  print('multi => $multiResult');
}

Future<void> runWatchTransaction(Redis redis) async {
  print('\n== WATCH transaction ==');

  await redis.set('example:watch:source', 'ready');
  final tx = await redis.watch(<String>['example:watch:source']);
  tx.set('example:watch:result', 'committed');
  final result = await tx.exec();

  if (result == null) {
    print('watch exec => aborted (watched key changed)');
  } else {
    print('watch exec => committed with ${result.length} replies');
  }
}

Future<void> runScanIterators(Redis redis) async {
  print('\n== SCAN iterators ==');

  for (var i = 0; i < 3; i++) {
    await redis.set('example:scan:key:$i', 'value:$i');
  }

  final keys =
      await redis.scanIterator(match: 'example:scan:key:*', count: 2).toList();
  print('scan keys => $keys');
}

Future<void> runBinaryOps(Redis redis) async {
  print('\n== Binary SET/GET ==');

  final payload = Uint8List.fromList(<int>[0, 1, 2, 3, 255, 254, 128]);
  await redis.setBuffer('example:binary', payload);
  final received = await redis.getBuffer('example:binary');
  print('binary roundtrip bytes => ${received?.length}');
}

Future<void> runPubSub(Redis pub, Redis sub) async {
  print('\n== Pub/Sub ==');

  final completer = Completer<String?>();
  final listener = await sub.subscribe('example:events');
  listener.onMessage = (channel, message) {
    if (channel == 'example:events' && !completer.isCompleted) {
      completer.complete(message);
    }
  };

  await pub.publish('example:events', 'hello-subscribers');
  final message = await completer.future.timeout(const Duration(seconds: 2));
  print('pub/sub message => $message');

  await sub.unsubscribe('example:events');
}

Future<void> runJsonOps(Redis redis) async {
  print('\n== RedisJSON (optional module) ==');

  try {
    await redis.jsonSet('example:json:1', '.', <String, dynamic>{
      'name': 'redis-sdk',
      'version': 1,
      'features': <String>['pipeline', 'watch', 'pubsub'],
    });
    final full = await redis.jsonGet('example:json:1', '.');
    final name = await redis.jsonGet('example:json:1', '.name');
    print('json full => $full');
    print('json name => $name');
  } catch (error) {
    print('RedisJSON unavailable: $error');
  }
}

Future<void> cleanup(Redis redis) async {
  await redis.mdelete(<String>[
    'example:user:1',
    'example:user:2',
    'example:pipe:1',
    'example:pipe:2',
    'example:tx:1',
    'example:tx:2',
    'example:watch:source',
    'example:watch:result',
    'example:scan:key:0',
    'example:scan:key:1',
    'example:scan:key:2',
    'example:binary',
  ]);

  try {
    await redis.delete('example:json:1');
  } catch (_) {
    // ignore when JSON key handling differs without RedisJSON
  }
}
