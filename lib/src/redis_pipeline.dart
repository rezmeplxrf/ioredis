import 'package:ioredis/ioredis.dart';

class RedisPipeline {
  RedisPipeline(this._redis);

  final Redis _redis;
  final List<List<String>> _commands = <List<String>>[];

  RedisPipeline command(List<String> command) {
    _commands.add(List<String>.from(command));
    return this;
  }

  RedisPipeline set(String key, String value,
      [String? option, dynamic optionValue]) {
    _commands.add(_redis.getCommandToSetData(key, value, option, optionValue));
    return this;
  }

  RedisPipeline get(String key) {
    _commands.add(_redis.getCommandToGetData(key));
    return this;
  }

  RedisPipeline delete(String key) {
    _commands.add(<String>['DEL', _redis.prefixedKey(key)]);
    return this;
  }

  Future<List<dynamic>> exec({Duration? timeout, int? batchSize}) async {
    final commands = List<List<String>>.from(_commands);
    _commands.clear();
    if (commands.isEmpty) {
      return <dynamic>[];
    }
    return _redis.sendPipeline(
      commands,
      timeout: timeout,
      batchSize: batchSize,
    );
  }
}
