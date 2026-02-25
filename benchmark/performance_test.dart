import 'dart:typed_data';

import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:ioredis/src/redis_response.dart';
import 'package:ioredis/src/transformer.dart';

Future<void> main() async {
  benchmarkResponseParsing();
  await benchmarkTransformer();
  benchmarkMessageEncoding();
}

void benchmarkResponseParsing() {
  print('=== RESP Parsing Benchmark ===');

  final cases = <({String name, Uint8List payload, int iterations})>[
    (
      name: 'simple string +OK',
      payload: Uint8List.fromList('+OK\r\n'.codeUnits),
      iterations: 300000,
    ),
    (
      name: 'integer :42',
      payload: Uint8List.fromList(':42\r\n'.codeUnits),
      iterations: 300000,
    ),
    (
      name: r'bulk $5 hello',
      payload: Uint8List.fromList('\$5\r\nhello\r\n'.codeUnits),
      iterations: 250000,
    ),
    (
      name: 'array [foo,bar,baz]',
      payload: Uint8List.fromList(
          '*3\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n\$3\r\nbaz\r\n'.codeUnits),
      iterations: 120000,
    ),
    (
      name: 'RESP3 map %2',
      payload: Uint8List.fromList('%2\r\n+a\r\n:1\r\n+b\r\n:2\r\n'.codeUnits),
      iterations: 100000,
    ),
    (
      name: 'RESP3 push message',
      payload:
          Uint8List.fromList('>3\r\n+message\r\n+room\r\n+hello\r\n'.codeUnits),
      iterations: 100000,
    ),
  ];

  for (final c in cases) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < c.iterations; i++) {
      RedisResponse.tryParseBytesWithConsumed(c.payload);
    }
    sw.stop();

    final micros = sw.elapsedMicroseconds;
    final perOp = micros / c.iterations;
    final opsPerSec = c.iterations * 1000000 / micros;
    print(
      '${c.name.padRight(22)} '
      'total=${micros}us '
      'avg=${perOp.toStringAsFixed(3)}us '
      'ops/s=${opsPerSec.toStringAsFixed(0)}',
    );
  }
  print('');
}

Future<void> benchmarkTransformer() async {
  print('=== Stream Transformer Benchmark ===');

  final oneFrame =
      Uint8List.fromList('*2\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n'.codeUnits);
  const frames = 40000;

  final chunks = <Uint8List>[];
  for (var i = 0; i < frames; i++) {
    chunks.add(oneFrame);
  }

  final sw = Stopwatch()..start();
  var count = 0;
  final stream = Stream<Uint8List>.fromIterable(chunks)
      .transform(BufferedRedisResponseTransformer());

  await stream.forEach((_) {
    count++;
  });
  sw.stop();
  final micros = sw.elapsedMicroseconds;
  final opsPerSec = count * 1000000 / micros;
  print(
      'frames=$count total=${micros}us ops/s=${opsPerSec.toStringAsFixed(0)}');
  print('');
}

void benchmarkMessageEncoding() {
  print('=== RESP Encoding Benchmark ===');

  final encoder = RedisMessageEncoder();
  final cases = <({String name, Object command, int iterations})>[
    (
      name: 'GET key',
      command: <String>['GET', 'bench:key'],
      iterations: 300000,
    ),
    (
      name: 'SET key value',
      command: <String>['SET', 'bench:key', 'hello'],
      iterations: 250000,
    ),
    (
      name: 'MGET 10 keys',
      command: <String>[
        'MGET',
        'k1',
        'k2',
        'k3',
        'k4',
        'k5',
        'k6',
        'k7',
        'k8',
        'k9',
        'k10',
      ],
      iterations: 120000,
    ),
    (
      name: 'EVALSHA small',
      command: <String>['EVALSHA', 'abc', '1', 'k1', 'arg1'],
      iterations: 120000,
    ),
    (
      name: 'LPUSH 100 values',
      command: <String>[
        'LPUSH',
        'bench:list',
        ...List<String>.generate(100, (i) => 'item:$i'),
      ],
      iterations: 30000,
    ),
  ];

  for (final c in cases) {
    final sw = Stopwatch()..start();
    var bytes = 0;
    for (var i = 0; i < c.iterations; i++) {
      bytes += encoder.encode(c.command).length;
    }
    sw.stop();

    final micros = sw.elapsedMicroseconds;
    final perOp = micros / c.iterations;
    final opsPerSec = c.iterations * 1000000 / micros;
    print(
      '${c.name.padRight(18)} '
      'total=${micros}us '
      'avg=${perOp.toStringAsFixed(3)}us '
      'ops/s=${opsPerSec.toStringAsFixed(0)} '
      'bytes=$bytes',
    );
  }
  print('');
}
