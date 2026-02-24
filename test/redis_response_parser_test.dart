import 'dart:async';

import 'package:ioredis/src/redis_response.dart';
import 'package:ioredis/src/transformer.dart';
import 'package:test/test.dart';

void main() {
  group('RedisResponse nested arrays', () {
    test('parses nested arrays without invalid casts', () {
      const resp =
          '*2\r\n*2\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n\$3\r\nbaz\r\n';

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
  });
}
