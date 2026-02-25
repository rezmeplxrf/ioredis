import 'package:ioredis/ioredis.dart';

class RedisMulti {
  RedisMulti(this._redis);
  final Redis _redis;

  final List<List<Object?>> _commands = <List<Object?>>[];

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
  RedisMulti command(List<Object?> command) {
    _commands.add(List<Object?>.from(command));
    return this;
  }

  RedisMulti commandArgs(String name,
      [List<Object?> args = const <Object?>[]]) {
    _commands.add(<Object?>[name, ...args]);
    return this;
  }

  /// exec multi command
  Future<List<dynamic>> exec() async {
    final commands = List<List<Object?>>.from(_commands);
    _commands.clear();
    return _redis.executeMulti(commands);
  }
}
