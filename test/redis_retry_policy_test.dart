import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('RedisRetryPolicy |', () {
    test('respects max attempts', () {
      const policy = RedisRetryPolicy(maxAttempts: 2);
      final error = RedisConnectionError('down');
      expect(policy.canRetry(error, 1, const <String>['GET', 'k']), isTrue);
      expect(policy.canRetry(error, 2, const <String>['GET', 'k']), isFalse);
    });

    test('applies full jitter within range', () {
      const policy = RedisRetryPolicy(
        maxAttempts: 3,
        initialDelay: Duration(milliseconds: 100),
        maxDelay: Duration(milliseconds: 200),
        jitter: RedisRetryJitter.full,
      );
      final delay = policy.nextDelay(1);
      expect(delay.inMilliseconds, inInclusiveRange(0, 100));
    });
  });
}
