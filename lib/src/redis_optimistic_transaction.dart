import 'package:ioredis/ioredis.dart';

class RedisOptimisticTransaction {
  RedisOptimisticTransaction._(this._redis);

  final Redis _redis;
  final List<List<String>> _commands = <List<String>>[];
  bool _closed = false;

  static Future<RedisOptimisticTransaction> start({
    required RedisOptions option,
    required List<String> keys,
  }) async {
    final redis = Redis(option);
    final transaction = RedisOptimisticTransaction._(redis);
    try {
      if (keys.isNotEmpty) {
        await redis.connection.sendCommand(<String>['WATCH', ...keys]);
      }
      return transaction;
    } catch (_) {
      await redis.disconnect();
      rethrow;
    }
  }

  RedisOptimisticTransaction set(
    String key,
    String value, [
    String? option,
    dynamic optionValue,
  ]) {
    _ensureOpen();
    _commands.add(_redis.getCommandToSetData(key, value, option, optionValue));
    return this;
  }

  RedisOptimisticTransaction get(String key) {
    _ensureOpen();
    _commands.add(_redis.getCommandToGetData(key));
    return this;
  }

  RedisOptimisticTransaction delete(String key) {
    _ensureOpen();
    _commands.add(<String>['DEL', _redis.prefixedKey(key)]);
    return this;
  }

  RedisOptimisticTransaction command(List<String> command) {
    _ensureOpen();
    _commands.add(List<String>.from(command));
    return this;
  }

  Future<List<dynamic>?> exec() async {
    _ensureOpen();
    final commands = List<List<String>>.from(_commands);
    _commands.clear();
    var multiStarted = false;
    var execSent = false;
    try {
      await _redis.connection.sendCommand(<String>['MULTI']);
      multiStarted = true;
      for (final command in commands) {
        await _redis.connection.sendCommand(command);
      }
      execSent = true;
      final result = await _redis.connection.sendCommand(<String>['EXEC']);
      if (result == null) {
        return null;
      }
      if (result is List<dynamic>) {
        return result;
      }
      throw StateError('Unexpected response for EXEC: ${result.runtimeType}');
    } catch (_) {
      if (multiStarted && !execSent) {
        try {
          await _redis.connection.sendCommand(<String>['DISCARD']);
        } catch (_) {}
      }
      rethrow;
    } finally {
      await close();
    }
  }

  Future<void> unwatch() async {
    _ensureOpen();
    try {
      await _redis.connection.sendCommand(<String>['UNWATCH']);
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _commands.clear();
    await _redis.disconnect();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Optimistic transaction is already closed');
    }
  }
}
