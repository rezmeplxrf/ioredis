// ignore_for_file: avoid_redundant_argument_values

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('Null retry strategy handling |', () {
    test('should handle null retryStrategy gracefully', () async {
      // Create Redis options without retryStrategy (it will be null)
      final options = RedisOptions(
        host: '127.0.0.1',
        port: 9999, // Non-existent port to trigger connection failure
        connectTimeout: const Duration(milliseconds: 100),
      );

      final redis = Redis(options);

      // This should not throw "Null check operator used on a null value"
      // Instead, it should handle the null retryStrategy gracefully
      expect(() async {
        try {
          await redis.connect();
        } catch (e) {
          // Connection failure is expected, but it should not be a null check error
          expect(e.toString(),
              isNot(contains('Null check operator used on a null value')));
        }
      }, returnsNormally);
    });

    test('should use default retry strategy when retryStrategy is null',
        () async {
      // Create Redis options without retryStrategy
      final options = RedisOptions(
        host: '127.0.0.1',
        port: 9998, // Non-existent port
        connectTimeout: const Duration(milliseconds: 50),
      );

      final redis = Redis(options);

      final startTime = DateTime.now();

      try {
        await redis.connect();
      } catch (e) {
        final endTime = DateTime.now();
        final duration = endTime.difference(startTime);

        // Should have tried to reconnect at least once with a delay
        // The default retry strategy should add some delay
        expect(duration.inMilliseconds, greaterThan(50));

        // Should not throw null check error
        expect(e.toString(),
            isNot(contains('Null check operator used on a null value')));
      }
    });
  });
}
