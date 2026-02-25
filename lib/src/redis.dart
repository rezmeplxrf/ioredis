import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_connection_pool.dart';
import 'package:ioredis/src/redis_multi_command.dart';
import 'package:ioredis/src/redis_response.dart';

class Redis {
  Redis([RedisOptions? opt]) {
    if (opt != null) {
      option = opt;
    }
    connection = RedisConnection(option);
    pool = RedisConnectionPool(option, connection);
  }
  late RedisConnection connection;

  late RedisOptions option = defaultRedisOptions;

  late RedisConnectionPool pool;

  /// Redis client type
  /// subscriber, publisher or normal set and get
  RedisType redisClientType = RedisType.normal;

  final Random _retryRandom = Random();

  /// Set custom socket
  void setSocket(Socket socket) {
    connection.setSocket(socket);
  }

  /// Connect to redis connection
  /// This call can be optional. If it function did not invoke initially,
  /// it will get call on first redis command.
  Future<void> connect() async {
    await connection.connect();
  }

  /// Disconnect to redis connection
  Future<void> disconnect() async {
    pool.dispose();
    await connection.disconnect();
    redisClientType = RedisType.normal;
  }

  /// Duplicate new redis connection
  Redis duplicate() {
    return Redis(option);
  }

  /// Set key value to redis
  /// ```dart
  /// await redis.set('foo', 'bar');
  /// ```
  Future<dynamic> set(String key, String value,
      [String? option, dynamic optionValue]) async {
    final val = await sendCommand(
      getCommandToSetData(key, value, option, optionValue),
    ) as String?;
    if (!RedisResponse.ok(val)) {
      throw RedisProtocolError('SET expected OK but got: $val');
    }
  }

  /// Get value of a key
  /// ```dart
  /// await redis.get('foo');
  /// ```
  Future<String?> get(String key) async {
    return await sendCommand(getCommandToGetData(key)) as String?;
  }

  /// Get value of a key
  /// ```dart
  /// await redis.get('foo');
  /// ```
  Future<List<String?>> mget(List<String> keys) async {
    if (keys.isEmpty) {
      return <String?>[];
    }
    final result =
        await sendCommand(<String>['MGET', ..._setPrefixInKeys(keys)]);
    if (result is List) {
      return result.cast<String?>();
    }
    throw RedisProtocolError(
        'Unexpected response for MGET: ${result.runtimeType}');
  }

  /// Delete a key
  /// ```dart
  /// await redis.get('foo');
  /// ```
  Future<void> delete(String key) async {
    await sendCommand(<String>['DEL', prefixedKey(key)]);
  }

  /// Delete multiple key
  /// ```dart
  /// await redis.get('foo');
  /// ```
  Future<void> mdelete(List<String> keys) async {
    if (keys.isEmpty) {
      return;
    }
    await sendCommand(<String>['DEL', ..._setPrefixInKeys(keys)]);
  }

  /// flush all they data from currently selected DB
  /// ```dart
  /// await redis.flushdb();
  /// ```
  Future<void> flushdb() async {
    await sendCommand(<String>['FLUSHDB']);
  }

  /// multi commands
  /// ```dart
  /// List<dynamic> result = await redis.multi()
  ///      .set('foo', 'bar')
  ///      .set('bar', 'foo')
  ///      .get('foo')
  ///      .get('bar')
  ///      .exec();
  /// ```
  RedisMulti multi() {
    return RedisMulti(this);
  }

  /// command pipeline with batched writes and ordered responses.
  RedisPipeline pipeline() {
    return RedisPipeline(this);
  }

  /// Subscribe to channel
  /// ```dart
  /// RedisSubscriber subscriber = await redis.subscribe('channel');
  ///
  /// subscriber.onMessage = (String channel,String? message) {
  ///
  /// }
  /// ```
  Future<RedisSubscriber> subscribe(String channel) async {
    if (redisClientType == RedisType.publisher) {
      throw RedisProtocolError(
          'cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.subscriber;

    final cb = RedisSubscriber(
      channel: channel,
      isPattern: false,
      onUnsubscribe: () => unsubscribe(channel),
    );
    connection.addSubscriber(cb);
    try {
      await sendCommand(<String>['SUBSCRIBE', channel]);
      return cb;
    } catch (_) {
      connection.removeSubscriber(channel, isPattern: false);
      _refreshClientType();
      rethrow;
    }
  }

  Future<RedisSubscriber> psubscribe(String pattern) async {
    if (redisClientType == RedisType.publisher) {
      throw RedisProtocolError(
          'cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.subscriber;

    final cb = RedisSubscriber(
      channel: pattern,
      isPattern: true,
      onUnsubscribe: () => punsubscribe(pattern),
    );
    connection.addSubscriber(cb);
    try {
      await sendCommand(<String>['PSUBSCRIBE', pattern]);
      return cb;
    } catch (_) {
      connection.removeSubscriber(pattern, isPattern: true);
      _refreshClientType();
      rethrow;
    }
  }

  Future<void> unsubscribe([String? channel]) async {
    if (channel != null) {
      await sendCommand(<String>['UNSUBSCRIBE', channel]);
    } else {
      await sendCommand(<String>['UNSUBSCRIBE']);
    }
    _refreshClientType();
  }

  Future<void> punsubscribe([String? pattern]) async {
    if (pattern != null) {
      await sendCommand(<String>['PUNSUBSCRIBE', pattern]);
    } else {
      await sendCommand(<String>['PUNSUBSCRIBE']);
    }
    _refreshClientType();
  }

  /// Publish message to a channel
  /// ```dart
  /// await redis.publish('chat', 'hello')
  /// ```
  Future<void> publish(String channel, String message) async {
    if (redisClientType == RedisType.subscriber) {
      throw RedisProtocolError(
          'cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.publisher;
    await sendCommand(<String>['PUBLISH', channel, message]);
  }

  /// send command to connection
  Future<dynamic> sendCommand(
    List<String> commandList, {
    Duration? timeout,
    RedisRetryPolicy? retryPolicy,
  }) async {
    final policy = retryPolicy ?? option.retryPolicy;
    var attempt = 1;

    while (true) {
      try {
        if (!connection.isBusy || redisClientType != RedisType.normal) {
          return await connection.sendCommand(commandList, timeout: timeout);
        }
        return await pool.sendCommand(commandList, timeout: timeout);
      } catch (error) {
        final mapped = RedisErrorMapper.map(error, command: commandList);
        if (policy == null || !policy.canRetry(mapped, attempt, commandList)) {
          throw mapped;
        }
        await Future<void>.delayed(policy.nextDelay(attempt, _retryRandom));
        attempt++;
      }
    }
  }

  /// send pipeline on the main connection using a single batched write.
  Future<List<dynamic>> sendPipeline(
    List<List<String>> commands, {
    Duration? timeout,
  }) async {
    return connection.sendPipeline(commands, timeout: timeout);
  }

  /// get command to set data to redis
  List<String> getCommandToSetData(String key, String value,
      [String? option, dynamic optionValue]) {
    final command = <String>['SET', prefixedKey(key), value];
    if (option != null && optionValue != null) {
      command.addAll(<String>[option.toUpperCase(), optionValue.toString()]);
    }
    return command;
  }

  /// get command to get data from redis
  List<String> getCommandToGetData(String key) {
    final command = <String>['GET', prefixedKey(key)];
    return command;
  }

  String prefixedKey(String key) {
    if (option.keyPrefix.isEmpty) {
      return key;
    }
    return '${option.keyPrefix}:$key';
  }

  /// setting keys prefix before setting or getting values
  List<String> _setPrefixInKeys(List<String> keys) {
    return keys.map(prefixedKey).toList();
  }

  void _refreshClientType() {
    if (connection.subscribeListeners.isNotEmpty) {
      redisClientType = RedisType.subscriber;
    } else {
      redisClientType = RedisType.normal;
    }
  }

  /// Get JSON value
  /// ```dart
  /// String? value = await redis.jsonGet('key', '$.path');
  /// ```
  Future<String?> jsonGet(String key, String path) async {
    final prefixedKey = _setPrefixInKeys(<String>[key]).first;
    return await sendCommand(['JSON.GET', prefixedKey, path]) as String?;
  }

  /// Set JSON value
  /// ```dart
  /// await redis.jsonSet('key', '$.path', '{"name":"John"}');
  /// ```
  Future<dynamic> jsonSet(String key, String path, dynamic jsonValue) async {
    // Convert the jsonValue to a JSON string if it's not already a string
    String jsonString;
    if (jsonValue is String) {
      jsonString = jsonValue;
    } else {
      try {
        jsonString = jsonEncode(jsonValue);
      } catch (e) {
        throw ArgumentError('Invalid JSON value');
      }
    }

    final val = await sendCommand([
      'JSON.SET',
      _setPrefixInKeys(<String>[key]).first,
      path,
      jsonString
    ]) as String?;
    if (!RedisResponse.ok(val)) {
      throw RedisProtocolError('JSON.SET expected OK but got: $val');
    }
  }

  /// Evaluate a Lua script atomically on Redis.
  ///
  /// ```dart
  /// final result = await redis.eval(
  ///   'return {KEYS[1],ARGV[1]}',
  ///   keys: ['k1'],
  ///   args: ['v1'],
  /// );
  /// ```
  Future<dynamic> eval(
    String script, {
    List<String> keys = const <String>[],
    List<dynamic> args = const <dynamic>[],
    Duration? timeout,
    RedisRetryPolicy? retryPolicy,
  }) async {
    final prefixedKeys = _setPrefixInKeys(keys);
    final command = <String>[
      'EVAL',
      script,
      prefixedKeys.length.toString(),
      ...prefixedKeys,
      ...args.map((arg) => arg.toString()),
    ];
    return sendCommand(command, timeout: timeout, retryPolicy: retryPolicy);
  }
}
