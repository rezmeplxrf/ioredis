import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ioredis/src/redis_response.dart';
import 'package:ioredis/src/transformer.dart';
import 'package:test/test.dart';

void main() {
  group('RedisResponse nested arrays', () {
    test('parses nested arrays without invalid casts', () {
      const resp = '*2\r\n*2\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n\$3\r\nbaz\r\n';

      final result = RedisResponse.transform(resp);

      expect(result, isA<List<dynamic>>());
      final list = result as List<dynamic>;
      expect(list.length, 2);
      expect(list.first, isA<List<dynamic>>());
      expect(list.first, ['foo', 'bar']);
      expect(list.last, 'baz');
    });

    test('returns consumed length for one response when multiple exist', () {
      const first = '*1\r\n\$3\r\nfoo\r\n';
      const second = '+OK\r\n';
      final parsed = RedisResponse.tryParseWithConsumed('$first$second');

      expect(parsed, isNotNull);
      expect(parsed!.$1, ['foo']);
      expect(parsed.$2, first.length);
    });

    test('parses integer responses as int', () {
      const resp = ':42\r\n';
      final result = RedisResponse.transform(resp);
      expect(result, isA<int>());
      expect(result, 42);
    });

    test('parses negative integer responses as int', () {
      const resp = ':-7\r\n';
      final result = RedisResponse.transform(resp);
      expect(result, isA<int>());
      expect(result, -7);
    });

    test('parses empty simple string as empty string', () {
      const resp = '+\r\n';
      final result = RedisResponse.transform(resp);
      expect(result, isA<String>());
      expect(result, equals(''));
    });

    test('parses nested arrays containing integers', () {
      const resp = '*2\r\n:1\r\n*2\r\n:2\r\n:3\r\n';
      final result = RedisResponse.transform(resp);
      expect(result, isA<List<dynamic>>());
      expect(
          result,
          equals(<dynamic>[
            1,
            <dynamic>[2, 3]
          ]));
    });

    test('byte parser keeps bulk data as raw bytes', () {
      final bytes = Uint8List.fromList(<int>[36, 0, 255]);
      final payload = Uint8List.fromList(<int>[
        36, 51, 13, 10, // $3\r\n
        ...bytes,
        13, 10, // \r\n
      ]);
      final parsed = RedisResponse.tryParseBytesWithConsumed(payload);
      expect(parsed, isNotNull);
      expect(parsed!.$1, isA<RedisBulkData>());
      final bulk = parsed.$1 as RedisBulkData;
      expect(bulk.bytes, equals(bytes));
    });

    test('byte parser can parse directly from a buffer range', () {
      final payload = Uint8List.fromList(<int>[
        120,
        120,
        43,
        79,
        75,
        13,
        10,
        121,
      ]);
      final parsed =
          RedisResponse.tryParseBytesWithConsumedInRange(payload, 2, 7);
      expect(parsed, isNotNull);
      expect(parsed!.$1, equals('OK'));
      expect(parsed.$2, equals(5));
    });

    test('byte parser supports RESP3 map and set', () {
      final mapPayload = Uint8List.fromList(<int>[
        37, 49, 13, 10, // %1
        43, 97, 13, 10, // +a
        58, 49, 13, 10, // :1
      ]);
      final mapParsed = RedisResponse.tryParseBytesWithConsumed(mapPayload);
      expect(mapParsed, isNotNull);
      expect(mapParsed!.$1, isA<Map<dynamic, dynamic>>());
      final map = mapParsed.$1 as Map<dynamic, dynamic>;
      expect(map['a'], equals(1));

      final setPayload = Uint8List.fromList(<int>[
        126, 50, 13, 10, // ~2
        43, 120, 13, 10, // +x
        43, 121, 13, 10, // +y
      ]);
      final setParsed = RedisResponse.tryParseBytesWithConsumed(setPayload);
      expect(setParsed, isNotNull);
      expect(setParsed!.$1, isA<Set<dynamic>>());
      expect(setParsed.$1 as Set<dynamic>, equals(<dynamic>{'x', 'y'}));
    });

    test('byte parser supports RESP3 push with typed values', () {
      final payload = Uint8List.fromList(<int>[
        62, 51, 13, 10, // >3
        43, 109, 101, 115, 115, 97, 103, 101, 13, 10, // +message
        43, 99, 104, 13, 10, // +ch
        43, 104, 105, 13, 10, // +hi
      ]);
      final parsed = RedisResponse.tryParseBytesWithConsumed(payload);
      expect(parsed, isNotNull);
      expect(parsed!.$1, isA<RedisPushData>());
      final push = parsed.$1 as RedisPushData;
      expect(push.items, equals(<dynamic>['message', 'ch', 'hi']));
    });

    test('byte parser supports RESP3 bool/double/null', () {
      final payload = Uint8List.fromList(<int>[
        35, 116, 13, 10, // #t
        35, 102, 13, 10, // #f
        44, 51, 46, 49, 52, 13, 10, // ,3.14
        95, 13, 10, // _\r\n
      ]);
      final first = RedisResponse.tryParseBytesWithConsumed(payload);
      expect(first, isNotNull);
      expect(first!.$1, isTrue);

      final second = RedisResponse.tryParseBytesWithConsumed(
        Uint8List.sublistView(payload, first.$2),
      );
      expect(second, isNotNull);
      expect(second!.$1, isFalse);

      final third = RedisResponse.tryParseBytesWithConsumed(
        Uint8List.sublistView(payload, first.$2 + second.$2),
      );
      expect(third, isNotNull);
      expect(third!.$1, closeTo(3.14, 0.0001));

      final fourth = RedisResponse.tryParseBytesWithConsumed(
        Uint8List.sublistView(payload, first.$2 + second.$2 + third.$2),
      );
      expect(fourth, isNotNull);
      expect(fourth!.$1, isNull);
    });

    test('rejects invalid RESP3 boolean token', () {
      final payload = Uint8List.fromList(<int>[
        35, 120, 13, 10, // #x
      ]);
      final parsed = RedisResponse.tryParseBytesWithConsumed(payload);
      expect(parsed, isNull);
    });

    test('byte parser supports RESP3 bigint', () {
      final payload = Uint8List.fromList(<int>[
        40, // (
        ...'-9223372036854775809'.codeUnits,
        13, 10,
      ]);
      final parsed = RedisResponse.tryParseBytesWithConsumed(payload);
      expect(parsed, isNotNull);
      expect(parsed!.$1, isA<BigInt>());
      expect(parsed.$1.toString(), equals('-9223372036854775809'));
    });

    test('byte parser supports RESP3 attributes prefix', () {
      final payload = Uint8List.fromList(<int>[
        124, 49, 13, 10, // |1
        43, 109, 101, 116, 97, 13, 10, // +meta
        43, 118, 49, 13, 10, // +v1
        43, 79, 75, 13, 10, // +OK
      ]);
      final parsed = RedisResponse.tryParseBytesWithConsumed(payload);
      expect(parsed, isNotNull);
      expect(parsed!.$1, isA<RedisAttributedData>());
      final attributed = parsed.$1 as RedisAttributedData;
      expect(attributed.attributes['meta'], equals('v1'));
      expect(attributed.data, equals('OK'));
    });

    test('byte parser supports streamed RESP3 blob strings', () {
      final payload = Uint8List.fromList(<int>[
        36, 63, 13, 10, // $?
        59, 53, 13, 10, // ;5
        ...'hello'.codeUnits,
        13, 10,
        59, 49, 13, 10, // ;1
        ...'!'.codeUnits,
        13, 10,
        59, 48, 13, 10, // ;0
        13, 10,
      ]);
      final parsed = RedisResponse.tryParseBytesWithConsumed(payload);
      expect(parsed, isNotNull);
      expect(parsed!.$1, isA<RedisBulkData>());
      final bulk = parsed.$1 as RedisBulkData;
      expect(utf8.decode(bulk.bytes), equals('hello!'));
    });

    test('byte parser supports streamed RESP3 aggregates', () {
      final arrayPayload = Uint8List.fromList(<int>[
        42, 63, 13, 10, // *?
        43, 97, 13, 10, // +a
        58, 49, 13, 10, // :1
        46, 13, 10, // .
      ]);
      final arrayParsed = RedisResponse.tryParseBytesWithConsumed(arrayPayload);
      expect(arrayParsed, isNotNull);
      expect(arrayParsed!.$1, equals(<dynamic>['a', 1]));

      final mapPayload = Uint8List.fromList(<int>[
        37, 63, 13, 10, // %?
        43, 107, 13, 10, // +k
        43, 118, 13, 10, // +v
        46, 13, 10, // .
      ]);
      final mapParsed = RedisResponse.tryParseBytesWithConsumed(mapPayload);
      expect(mapParsed, isNotNull);
      expect(mapParsed!.$1, equals(<dynamic, dynamic>{'k': 'v'}));

      final setPayload = Uint8List.fromList(<int>[
        126, 63, 13, 10, // ~?
        43, 120, 13, 10, // +x
        43, 121, 13, 10, // +y
        46, 13, 10, // .
      ]);
      final setParsed = RedisResponse.tryParseBytesWithConsumed(setPayload);
      expect(setParsed, isNotNull);
      expect(setParsed!.$1, equals(<dynamic>{'x', 'y'}));

      final pushPayload = Uint8List.fromList(<int>[
        62, 63, 13, 10, // >?
        43, 109, 101, 115, 115, 97, 103, 101, 13, 10, // +message
        43, 114, 111, 111, 109, 13, 10, // +room
        43, 104, 105, 13, 10, // +hi
        46, 13, 10, // .
      ]);
      final pushParsed = RedisResponse.tryParseBytesWithConsumed(pushPayload);
      expect(pushParsed, isNotNull);
      expect(pushParsed!.$1, isA<RedisPushData>());
      final push = pushParsed.$1 as RedisPushData;
      expect(push.items, equals(<dynamic>['message', 'room', 'hi']));
    });
  });

  group('BufferedRedisResponseTransformer', () {
    test('keeps trailing responses in buffer after parsing array', () async {
      const first = '*1\r\n\$3\r\nfoo\r\n';
      const second = '+OK\r\n';
      final source = Stream<String>.fromIterable([first + second]);

      final values = await source.transform(redisResponseTransformer).toList();

      expect(values.length, 2);
      expect(values[0], ['foo']);
      expect(values[1], 'OK');
    });

    test('handles nested arrays across chunks', () async {
      const part1 = '*2\r\n*2\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n';
      const part2 = '\$3\r\nbaz\r\n';
      final controller = StreamController<String>();

      unawaited(() async {
        controller.add(part1);
        controller.add(part2);
        await controller.close();
      }());

      final values =
          await controller.stream.transform(redisResponseTransformer).toList();

      expect(values.length, 1);
      expect(values.first, [
        ['foo', 'bar'],
        'baz'
      ]);
    });

    test('parses streamed RESP3 array in string transformer', () async {
      const payload = '*?\r\n+a\r\n:1\r\n.\r\n';
      final values = await Stream<String>.value(payload)
          .transform(redisResponseTransformer)
          .toList();
      expect(values.length, 1);
      expect(values.first, equals(<dynamic>['a', 1]));
    });

    test('parses streamed RESP3 blob string in string transformer', () async {
      const part1 = r'$?' '\r\n' ';5' '\r\n' 'hello' '\r\n';
      const part2 = ';1' '\r\n' '!' '\r\n' ';0' '\r\n' '\r\n';
      final values = await Stream<String>.fromIterable(<String>[part1, part2])
          .transform(redisResponseTransformer)
          .toList();
      expect(values.length, 1);
      expect(values.first, equals('hello!'));
    });
  });

  group('BufferedRedisResponseTransformer (bytes)', () {
    test('parses multiple responses from chunked byte stream', () async {
      final part1 = Uint8List.fromList(<int>[
        43, 79, 75, 13, 10, // +OK\r\n
        58, 52, 50, 13, // :42\r (partial)
      ]);
      final part2 = Uint8List.fromList(<int>[
        10, // \n
        36, 51, 13, 10, // $3\r\n
        102, 111, 111, 13, 10, // foo\r\n
      ]);
      final source = Stream<Uint8List>.fromIterable(<Uint8List>[
        part1,
        part2,
      ]);

      final values =
          await source.transform(BufferedRedisResponseTransformer()).toList();
      expect(values.length, 3);
      expect(values[0], equals('OK'));
      expect(values[1], equals(42));
      expect(values[2], isA<RedisBulkData>());
      final bulk = values[2] as RedisBulkData;
      expect(bulk.bytes, equals(Uint8List.fromList(<int>[102, 111, 111])));
    });

    test('handles fragmented nested arrays across many byte chunks', () async {
      final chunks = <Uint8List>[
        Uint8List.fromList('*2\r\n*2\r\n\$3\r\nfoo\r\n'.codeUnits),
        Uint8List.fromList('\$3\r\nbar\r\n'.codeUnits),
        Uint8List.fromList('\$3\r\nbaz\r\n'.codeUnits),
      ];
      final controller = StreamController<Uint8List>();
      unawaited(() async {
        chunks.forEach(controller.add);
        await controller.close();
      }());

      final values = await controller.stream
          .transform(BufferedRedisResponseTransformer())
          .toList();
      expect(values.length, 1);
      final top = values.first as List<dynamic>;
      expect(top[0], isA<List<dynamic>>());
      final nested = top[0] as List<dynamic>;
      expect(nested.length, 2);
      expect(nested[0], isA<RedisBulkData>());
      expect(nested[1], isA<RedisBulkData>());
      final nestedFirst = nested[0] as RedisBulkData;
      final nestedSecond = nested[1] as RedisBulkData;
      expect(nestedFirst.bytes, equals(Uint8List.fromList('foo'.codeUnits)));
      expect(nestedSecond.bytes, equals(Uint8List.fromList('bar'.codeUnits)));
      expect(top[1], isA<RedisBulkData>());
      final bulk = top[1] as RedisBulkData;
      expect(bulk.bytes, equals(Uint8List.fromList('baz'.codeUnits)));
    });
  });
}
