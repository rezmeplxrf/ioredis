import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    await connection.disconnect();
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
    final val =
        await sendCommand(getCommandToSetData(key, value, option, optionValue))
            as String?;
    if (!RedisResponse.ok(val)) {
      throw Exception(val);
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
    return await sendCommand(<String>['MGET', ..._setPrefixInKeys(keys)])
        as List<String?>;
  }

  /// Delete a key
  /// ```dart
  /// await redis.get('foo');
  /// ```
  Future<void> delete(String key) async {
    await sendCommand(<String>[
      'DEL',
      _setPrefixInKeys(<String>[key]).first
    ]);
  }

  /// Delete multiple key
  /// ```dart
  /// await redis.get('foo');
  /// ```
  Future<void> mdelete(List<String> keys) async {
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
      throw Exception('cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.subscriber;

    final cb = RedisSubscriber(channel: channel);
    connection.subscribeListeners.add(cb);
    unawaited(sendCommand(<String>['SUBSCRIBE', channel]));
    return cb;
  }

  Future<RedisSubscriber> psubscribe(String pattern) async {
    if (redisClientType == RedisType.publisher) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.subscriber;

    final cb = RedisSubscriber(channel: pattern);
    connection.subscribeListeners.add(cb);
    unawaited(sendCommand(<String>['PSUBSCRIBE', pattern]));
    return cb;
  }

  /// Publish message to a channel
  /// ```dart
  /// await redis.publish('chat', 'hello')
  /// ```
  Future<void> publish(String channel, String message) async {
    if (redisClientType == RedisType.subscriber) {
      throw Exception('cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.publisher;
    await sendCommand(<String>['PUBLISH', channel, message]);
  }

  /// send command to connection
  Future<dynamic> sendCommand(List<String> commandList) async {
    if (connection.isBusy == false || redisClientType != RedisType.normal) {
      return connection.sendCommand(commandList);
    }
    return pool.sendCommand(commandList);
  }

  /// get command to set data to redis
  List<String> getCommandToSetData(String key, String value,
      [String? option, dynamic optionValue]) {
    final command = <String>[
      'SET',
      _setPrefixInKeys(<String>[key]).first,
      value
    ];
    if (option != null && optionValue != null) {
      command.addAll(<String>[option.toUpperCase(), optionValue.toString()]);
    }
    return command;
  }

  /// get command to get data from redis
  List<String> getCommandToGetData(String key) {
    final command = <String>[
      'GET',
      _setPrefixInKeys(<String>[key]).first
    ];
    return command;
  }

  /// setting keys prefix before setting or getting values
  List<String> _setPrefixInKeys(List<String> keys) {
    return keys
        .map((String k) =>
            option.keyPrefix.isNotEmpty ? '${option.keyPrefix}:$k' : k)
        .toList();
  }

  /// Get JSON value
  /// ```dart
  /// String? value = await redis.jsonGet('key', '$.path');
  /// ```
  Future<String?> jsonGet(String key, String path) async {
    return await sendCommand(['JSON.GET', key, path]) as String?;
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

    final val =
        await sendCommand(['JSON.SET', key, path, jsonString]) as String?;
    if (!RedisResponse.ok(val)) {
      throw Exception(val);
    }
  }
}
