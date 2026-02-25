import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('RedisErrorMapper |', () {
    test('maps auth errors', () {
      final error =
          RedisErrorMapper.fromServerError('NOAUTH Authentication required.');
      expect(error, isA<RedisAuthError>());
    });

    test('maps moved errors', () {
      final error =
          RedisErrorMapper.fromServerError('MOVED 1234 127.0.0.1:7001');
      expect(error, isA<RedisMovedError>());
      final moved = error as RedisMovedError;
      expect(moved.slot, 1234);
      expect(moved.host, '127.0.0.1');
      expect(moved.port, 7001);
    });

    test('maps ask errors', () {
      final error = RedisErrorMapper.fromServerError('ASK 4 127.0.0.1:7002');
      expect(error, isA<RedisAskError>());
      final ask = error as RedisAskError;
      expect(ask.slot, 4);
      expect(ask.host, '127.0.0.1');
      expect(ask.port, 7002);
    });

    test('maps generic command errors', () {
      final error = RedisErrorMapper.fromServerError('ERR unknown command');
      expect(error, isA<RedisCommandError>());
      final commandError = error as RedisCommandError;
      expect(commandError.code, 'ERR');
    });
  });
}
