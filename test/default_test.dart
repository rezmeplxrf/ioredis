// ignore_for_file: prefer_final_locals, unnecessary_null_checks

import 'package:ioredis/src/default.dart';
import 'package:test/test.dart';

void main() {
  group('default values', () {
    test('options', () {
      expect(defaultRedisOptions.host, '127.0.0.1');
      expect(defaultRedisOptions.port, 6379);
      expect(defaultRedisOptions.connectTimeout, const Duration(seconds: 10));
      expect(defaultRedisOptions.db, 0);
      expect(defaultRedisOptions.secure, false);

      Duration Function(int p1)? retryStrategy =
          defaultRedisOptions.retryStrategy!;

      expect(retryStrategy(1), const Duration(milliseconds: 50));
      expect(retryStrategy(2), const Duration(milliseconds: 100));
      expect(retryStrategy(3), const Duration(milliseconds: 150));
      expect(retryStrategy(100), const Duration(milliseconds: 2000));
    });
  });
}
