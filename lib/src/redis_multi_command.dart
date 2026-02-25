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
    return _redis.executeMulti(commands);
  }
}
