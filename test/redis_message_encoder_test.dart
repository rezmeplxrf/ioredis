import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:test/test.dart';

RedisMessageEncoder encoder = RedisMessageEncoder();

void main() {
  group('protocol message encoder', () {
    test('string', () {
      final val = encoder.encode(<String>['GET', 'key']);
      expect(true, val.isNotEmpty);
    });

    test('null', () {
      final val = encoder.encode(null);
      expect(true, val.isNotEmpty);
    });

    test('array with strings', () {
      final val = encoder.encode(<String>['SET', 'key', 'value']);
      expect(true, val.isNotEmpty);
    });

    test('array with int mixed', () {
      final val = encoder.encode(<dynamic>['SET', 'key', 1]);
      expect(true, val.isNotEmpty);
    });
  });
}
