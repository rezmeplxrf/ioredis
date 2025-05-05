import 'package:ioredis/ioredis.dart';

class RedisMulti {

  RedisMulti(this._redis);
  final Redis _redis;

  final List<List<String>> _commands = <List<String>>[];

  /// set value
  void set(String key, String value,
      [String? option, dynamic optionValue]) {
    _commands.add(_redis.getCommandToSetData(key, value, option, optionValue));

  }

  /// get value
  void get(String key) {
    _commands.add(_redis.getCommandToGetData(key));

  }

  /// exec multi command
  Future<List<dynamic>> exec() async {
    await _redis.sendCommand(<String>['MULTI']);
    for (final command in _commands) {
      await _redis.sendCommand(command);
    }
    return await _redis.sendCommand(<String>['EXEC']) as List<dynamic>;
  }
}
