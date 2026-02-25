import 'package:ioredis/ioredis.dart';

class RedisPipeline {
  RedisPipeline(this._redis);

  final Redis _redis;
  final List<List<Object?>> _commands = <List<Object?>>[];

  RedisPipeline command(List<Object?> command) {
    _commands.add(List<Object?>.from(command));
    return this;
  }

  RedisPipeline commandArgs(String name,
      [List<Object?> args = const <Object?>[]]) {
    _commands.add(<Object?>[name, ...args]);
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

  Future<List<dynamic>> exec({
    Duration? timeout,
    int? batchSize,
    RedisRetryPolicy? retryPolicy,
    bool rawReply = false,
  }) async {
    final commands = List<List<Object?>>.from(_commands);
    _commands.clear();
    if (commands.isEmpty) {
      return <dynamic>[];
    }
    if (rawReply) {
      return _redis.sendBufferPipeline(
        commands,
        timeout: timeout,
        batchSize: batchSize,
        retryPolicy: retryPolicy,
      );
    }
    return _redis.sendPipeline(
      commands,
      timeout: timeout,
      batchSize: batchSize,
      retryPolicy: retryPolicy,
    );
  }
}
