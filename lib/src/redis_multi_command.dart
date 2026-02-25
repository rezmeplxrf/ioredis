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

  /// exec multi command
  Future<List<dynamic>> exec() async {
    final commands = List<List<String>>.from(_commands);
    _commands.clear();

    await _redis.sendCommand(<String>['MULTI']);
    for (final command in commands) {
      await _redis.sendCommand(command);
    }
    final result = await _redis.sendCommand(<String>['EXEC']);
    if (result is List<dynamic>) {
      return result;
    }
    if (result == null) {
      return <dynamic>[];
    }
    throw StateError('Unexpected response for EXEC: ${result.runtimeType}');
  }
}
