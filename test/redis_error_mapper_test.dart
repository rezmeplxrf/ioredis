import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() {
  group('RedisErrorMapper |', () {
    test('maps auth errors', () {
      final error =
          RedisErrorMapper.fromServerError('NOAUTH Authentication required.');
      expect(error, isA<RedisAuthError>());
    });

    test('maps generic command errors', () {
      final error = RedisErrorMapper.fromServerError('ERR unknown command');
      expect(error, isA<RedisCommandError>());
      final commandError = error as RedisCommandError;
      expect(commandError.code, 'ERR');
    });
  });
}
