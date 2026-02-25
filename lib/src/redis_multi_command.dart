import 'package:ioredis/ioredis.dart';

class RedisMulti {
  RedisMulti(this._redis);
  final Redis _redis;

  final List<List<String>> _commands = <List<String>>[];

  /// set value
  RedisMulti set(String key, String value,
      [String? option, dynamic optionValue]) {
    _commands.add(_redis.getCommandToSetData(key, value, option, optionValue));
    return this;
  }

  /// get value
  RedisMulti get(String key) {
    _commands.add(_redis.getCommandToGetData(key));
    return this;
  }

  /// add a custom command
  RedisMulti command(List<String> command) {
    _commands.add(List<String>.from(command));
    return this;
  }

  /// exec multi command
  Future<List<dynamic>> exec() async {
    final commands = List<List<String>>.from(_commands);
    _commands.clear();

    final txRedis = _redis.duplicate();
    var multiStarted = false;
    var execSent = false;
    try {
      await txRedis.connection.sendCommand(<String>['MULTI']);
      multiStarted = true;
      for (final command in commands) {
        await txRedis.connection.sendCommand(command);
      }
      execSent = true;
      final result = await txRedis.connection.sendCommand(<String>['EXEC']);
      if (result is List<dynamic>) {
        return result;
      }
      if (result == null) {
        return <dynamic>[];
      }
      throw StateError('Unexpected response for EXEC: ${result.runtimeType}');
    } catch (_) {
      if (multiStarted && !execSent) {
        try {
          await txRedis.connection.sendCommand(<String>['DISCARD']);
        } catch (_) {}
      }
      rethrow;
    } finally {
      await txRedis.disconnect();
    }
  }
}
