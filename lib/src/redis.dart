import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_connection_pool.dart';
import 'package:ioredis/src/redis_multi_command.dart';
import 'package:ioredis/src/redis_response.dart';

class RedisClusterDiagnostics {
  const RedisClusterDiagnostics({
    required this.enabled,
    required this.knownNodeEndpoints,
    required this.knownSlotCount,
    required this.lastRefreshedAt,
  });

  final bool enabled;
  final List<String> knownNodeEndpoints;
  final int knownSlotCount;
  final DateTime? lastRefreshedAt;
}

class _ClusterRoutingPlan {
  const _ClusterRoutingPlan({
    required this.keys,
    required this.requiresSingleSlot,
  });

  final List<String> keys;
  final bool requiresSingleSlot;
}

class Redis {
  Redis([RedisOptions? opt]) {
    if (opt != null) {
      option = opt;
    }
    connection = RedisConnection(option);
    connection.onReconnect = _resubscribeActiveListeners;
    pool = RedisConnectionPool(option, connection);
  }
  late RedisConnection connection;

  late RedisOptions option = defaultRedisOptions;

  late RedisConnectionPool pool;
  final Map<String, RedisConnection> _clusterConnections =
      <String, RedisConnection>{};
  final Map<int, String> _clusterSlotToEndpoint = <int, String>{};
  DateTime? _clusterSlotsLastRefreshAt;
  DateTime? _sentinelLastResolveAt;

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
    await _ensureSentinelReady();
    await connection.connect();
  }

  /// Disconnect to redis connection
  Future<void> disconnect() async {
    pool.dispose();
    await connection.disconnect();
    for (final clusterConnection in _clusterConnections.values) {
      await clusterConnection.disconnect();
    }
    _clusterConnections.clear();
    _clusterSlotToEndpoint.clear();
    _clusterSlotsLastRefreshAt = null;
    _sentinelLastResolveAt = null;
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
      connection.removeSubscriber(channel, isPattern: false, isSharded: false);
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
      connection.removeSubscriber(pattern, isPattern: true, isSharded: false);
      _refreshClientType();
      rethrow;
    }
  }

  /// Subscribe to sharded channel
  Future<RedisSubscriber> ssubscribe(String channel) async {
    if (redisClientType == RedisType.publisher) {
      throw RedisProtocolError(
          'cannot subscribe and publish on same connection');
    }
    redisClientType = RedisType.subscriber;

    final cb = RedisSubscriber(
      channel: channel,
      isPattern: false,
      isSharded: true,
      onUnsubscribe: () => sunsubscribe(channel),
    );
    connection.addSubscriber(cb);
    try {
      await sendCommand(<String>['SSUBSCRIBE', channel]);
      return cb;
    } catch (_) {
      connection.removeSubscriber(channel, isPattern: false, isSharded: true);
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

  Future<void> sunsubscribe([String? channel]) async {
    if (channel != null) {
      await sendCommand(<String>['SUNSUBSCRIBE', channel]);
    } else {
      await sendCommand(<String>['SUNSUBSCRIBE']);
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
    await sendCommand(<String>['PUBLISH', channel, message]);
  }

  /// Publish message to a sharded channel
  Future<void> spublish(String channel, String message) async {
    if (redisClientType == RedisType.subscriber) {
      throw RedisProtocolError(
          'cannot subscribe and publish on same connection');
    }
    await sendCommand(<String>['SPUBLISH', channel, message]);
  }

  Future<int> hset(String key, String field, String value) async {
    final result =
        await sendCommand(<String>['HSET', prefixedKey(key), field, value]);
    return _toInt(result, command: 'HSET');
  }

  Future<String?> hget(String key, String field) async {
    return await sendCommand(<String>['HGET', prefixedKey(key), field])
        as String?;
  }

  Future<List<String?>> hmget(String key, List<String> fields) async {
    if (fields.isEmpty) return <String?>[];
    final result =
        await sendCommand(<String>['HMGET', prefixedKey(key), ...fields]);
    if (result is List) {
      return result.cast<String?>();
    }
    throw RedisProtocolError(
        'Unexpected response for HMGET: ${result.runtimeType}');
  }

  Future<int> lpush(String key, List<String> values) async {
    if (values.isEmpty) return 0;
    final result =
        await sendCommand(<String>['LPUSH', prefixedKey(key), ...values]);
    return _toInt(result, command: 'LPUSH');
  }

  Future<int> rpush(String key, List<String> values) async {
    if (values.isEmpty) return 0;
    final result =
        await sendCommand(<String>['RPUSH', prefixedKey(key), ...values]);
    return _toInt(result, command: 'RPUSH');
  }

  Future<List<String>> lrange(String key, int start, int stop) async {
    final result = await sendCommand(
        <String>['LRANGE', prefixedKey(key), '$start', '$stop']);
    if (result is List) {
      return result.cast<String>();
    }
    throw RedisProtocolError(
        'Unexpected response for LRANGE: ${result.runtimeType}');
  }

  Future<int> sadd(String key, List<String> members) async {
    if (members.isEmpty) return 0;
    final result =
        await sendCommand(<String>['SADD', prefixedKey(key), ...members]);
    return _toInt(result, command: 'SADD');
  }

  Future<List<String>> smembers(String key) async {
    final result = await sendCommand(<String>['SMEMBERS', prefixedKey(key)]);
    if (result is List) {
      return result.cast<String>();
    }
    throw RedisProtocolError(
        'Unexpected response for SMEMBERS: ${result.runtimeType}');
  }

  Future<int> zadd(String key, double score, String member) async {
    final result = await sendCommand(
      <String>['ZADD', prefixedKey(key), score.toString(), member],
    );
    return _toInt(result, command: 'ZADD');
  }

  Future<List<String>> zrange(
    String key,
    int start,
    int stop, {
    bool withScores = false,
  }) async {
    final command = <String>['ZRANGE', prefixedKey(key), '$start', '$stop'];
    if (withScores) {
      command.add('WITHSCORES');
    }
    final result = await sendCommand(command);
    if (result is List) {
      return result.cast<String>();
    }
    throw RedisProtocolError(
        'Unexpected response for ZRANGE: ${result.runtimeType}');
  }

  Future<String> xadd(
    String key,
    String id,
    Map<String, String> fields, {
    int? maxLen,
  }) async {
    if (fields.isEmpty) {
      throw ArgumentError('XADD fields must not be empty');
    }
    final command = <String>['XADD', prefixedKey(key)];
    if (maxLen != null) {
      command.addAll(<String>['MAXLEN', '~', '$maxLen']);
    }
    command.add(id);
    fields.forEach((field, value) {
      command.add(field);
      command.add(value);
    });
    final result = await sendCommand(command);
    if (result is String) {
      return result;
    }
    throw RedisProtocolError(
        'Unexpected response for XADD: ${result.runtimeType}');
  }

  Future<List<dynamic>> xrange(String key, String start, String end,
      {int? count}) async {
    final command = <String>['XRANGE', prefixedKey(key), start, end];
    if (count != null) {
      command.addAll(<String>['COUNT', '$count']);
    }
    final result = await sendCommand(command);
    if (result is List) {
      return result.cast<dynamic>();
    }
    throw RedisProtocolError(
        'Unexpected response for XRANGE: ${result.runtimeType}');
  }

  Future<String> scriptLoad(String script) async {
    final result = await sendCommand(<String>['SCRIPT', 'LOAD', script]);
    if (result is String) {
      return result;
    }
    throw RedisProtocolError(
        'Unexpected response for SCRIPT LOAD: ${result.runtimeType}');
  }

  Future<dynamic> evalsha(
    String sha, {
    List<String> keys = const <String>[],
    List<dynamic> args = const <dynamic>[],
    String? scriptOnNoScript,
    bool reloadOnNoScript = false,
    Duration? timeout,
    RedisRetryPolicy? retryPolicy,
  }) async {
    final prefixedKeys = _setPrefixInKeys(keys);
    final command = <String>[
      'EVALSHA',
      sha,
      prefixedKeys.length.toString(),
      ...prefixedKeys,
      ...args.map((arg) => arg.toString()),
    ];
    try {
      return await sendCommand(command,
          timeout: timeout, retryPolicy: retryPolicy);
    } on RedisCommandError catch (error) {
      final isNoScript = error.code == 'NOSCRIPT' ||
          error.message.toUpperCase().startsWith('NOSCRIPT');
      if (!isNoScript || !reloadOnNoScript || scriptOnNoScript == null) {
        rethrow;
      }
      final loaded = await scriptLoad(scriptOnNoScript);
      final retryCommand = <String>[
        'EVALSHA',
        loaded,
        prefixedKeys.length.toString(),
        ...prefixedKeys,
        ...args.map((arg) => arg.toString()),
      ];
      return sendCommand(retryCommand,
          timeout: timeout, retryPolicy: retryPolicy);
    }
  }

  Stream<String> scanIterator({
    String? match,
    int count = 100,
  }) async* {
    yield* _scanValues(
      command: 'SCAN',
      key: null,
      match: match,
      count: count,
    );
  }

  Stream<String> sscanIterator(
    String key, {
    String? match,
    int count = 100,
  }) async* {
    yield* _scanValues(
      command: 'SSCAN',
      key: prefixedKey(key),
      match: match,
      count: count,
    );
  }

  Stream<MapEntry<String, String>> hscanIterator(
    String key, {
    String? match,
    int count = 100,
  }) async* {
    await for (final values in _scanChunkValues(
      command: 'HSCAN',
      key: prefixedKey(key),
      match: match,
      count: count,
    )) {
      for (var i = 0; i + 1 < values.length; i += 2) {
        yield MapEntry(values[i], values[i + 1]);
      }
    }
  }

  Stream<MapEntry<String, double>> zscanIterator(
    String key, {
    String? match,
    int count = 100,
  }) async* {
    await for (final values in _scanChunkValues(
      command: 'ZSCAN',
      key: prefixedKey(key),
      match: match,
      count: count,
    )) {
      for (var i = 0; i + 1 < values.length; i += 2) {
        final score = double.tryParse(values[i + 1]);
        if (score != null) {
          yield MapEntry(values[i], score);
        }
      }
    }
  }

  /// send command to connection
  Future<dynamic> sendCommand(
    List<String> commandList, {
    Duration? timeout,
    RedisRetryPolicy? retryPolicy,
  }) async {
    await _ensureSentinelReady();
    final policy = retryPolicy ?? option.retryPolicy;
    var attempt = 1;
    var redirects = 0;
    final sw = Stopwatch()..start();

    while (true) {
      try {
        final routed = await _sendClusterRoutedCommandIfPossible(
          commandList,
          timeout: timeout,
        );
        if (routed != null) {
          return routed;
        }
        if (!connection.isBusy || redisClientType != RedisType.normal) {
          final result =
              await connection.sendCommand(commandList, timeout: timeout);
          _emitEvent(RedisEvent(
            type: RedisEventType.commandSuccess,
            command: commandList,
            duration: sw.elapsed,
          ));
          return result;
        }
        final result = await pool.sendCommand(commandList, timeout: timeout);
        _emitEvent(RedisEvent(
          type: RedisEventType.commandSuccess,
          command: commandList,
          duration: sw.elapsed,
        ));
        return result;
      } catch (error) {
        final mapped = RedisErrorMapper.map(error, command: commandList);
        if (option.enableClusterMode &&
            (mapped is RedisMovedError || mapped is RedisAskError)) {
          if (redirects >= option.maxClusterRedirects) {
            throw mapped;
          }
          redirects++;
          final endpoint = mapped is RedisMovedError
              ? '${mapped.host}:${mapped.port}'
              : () {
                  final ask = mapped as RedisAskError;
                  return '${ask.host}:${ask.port}';
                }();
          _emitEvent(RedisEvent(
            type: mapped is RedisMovedError
                ? RedisEventType.redirectMoved
                : RedisEventType.redirectAsk,
            command: commandList,
            endpoint: endpoint,
            attempt: redirects,
            error: mapped,
          ));
          if (mapped is RedisMovedError) {
            _clusterSlotToEndpoint[mapped.slot] =
                '${mapped.host}:${mapped.port}';
            unawaited(refreshClusterSlots(timeout: timeout));
          }
          final result = await _sendRedirectedCommand(
            commandList,
            mapped,
            timeout: timeout,
          );
          _emitEvent(RedisEvent(
            type: RedisEventType.commandSuccess,
            command: commandList,
            duration: sw.elapsed,
          ));
          return result;
        }
        if (option.enableSentinelMode &&
            mapped is RedisCommandError &&
            mapped.code == 'READONLY') {
          await refreshSentinelMaster(timeout: timeout);
          _emitEvent(RedisEvent(
            type: RedisEventType.commandRetry,
            command: commandList,
            attempt: attempt,
            error: mapped,
          ));
          attempt++;
          continue;
        }
        if (policy == null || !policy.canRetry(mapped, attempt, commandList)) {
          _emitEvent(RedisEvent(
            type: RedisEventType.commandError,
            command: commandList,
            duration: sw.elapsed,
            error: mapped,
          ));
          throw mapped;
        }
        _emitEvent(RedisEvent(
          type: RedisEventType.commandRetry,
          command: commandList,
          attempt: attempt,
          error: mapped,
        ));
        await Future<void>.delayed(policy.nextDelay(attempt, _retryRandom));
        attempt++;
      }
    }
  }

  /// send command expecting raw bulk replies (Uint8List).
  Future<dynamic> sendBufferCommand(
    List<Object?> commandList, {
    Duration? timeout,
    RedisRetryPolicy? retryPolicy,
  }) async {
    await _ensureSentinelReady();
    final policy = retryPolicy ?? option.retryPolicy;
    final commandForError = _commandSnapshot(commandList);
    var attempt = 1;
    var redirects = 0;
    final sw = Stopwatch()..start();

    while (true) {
      try {
        final routed = await _sendClusterRoutedBufferCommandIfPossible(
          commandList,
          timeout: timeout,
        );
        if (routed != null) {
          return routed;
        }
        final result =
            await connection.sendBufferCommand(commandList, timeout: timeout);
        _emitEvent(RedisEvent(
          type: RedisEventType.commandSuccess,
          command: commandForError,
          duration: sw.elapsed,
        ));
        return result;
      } catch (error) {
        final mapped = RedisErrorMapper.map(error, command: commandForError);
        if (option.enableClusterMode &&
            (mapped is RedisMovedError || mapped is RedisAskError)) {
          if (redirects >= option.maxClusterRedirects) {
            throw mapped;
          }
          redirects++;
          final endpoint = mapped is RedisMovedError
              ? '${mapped.host}:${mapped.port}'
              : () {
                  final ask = mapped as RedisAskError;
                  return '${ask.host}:${ask.port}';
                }();
          _emitEvent(RedisEvent(
            type: mapped is RedisMovedError
                ? RedisEventType.redirectMoved
                : RedisEventType.redirectAsk,
            command: commandForError,
            endpoint: endpoint,
            attempt: redirects,
            error: mapped,
          ));
          if (mapped is RedisMovedError) {
            _clusterSlotToEndpoint[mapped.slot] =
                '${mapped.host}:${mapped.port}';
            unawaited(refreshClusterSlots(timeout: timeout));
          }
          final result = await _sendRedirectedBufferCommand(
            commandList,
            mapped,
            timeout: timeout,
          );
          _emitEvent(RedisEvent(
            type: RedisEventType.commandSuccess,
            command: commandForError,
            duration: sw.elapsed,
          ));
          return result;
        }
        if (option.enableSentinelMode &&
            mapped is RedisCommandError &&
            mapped.code == 'READONLY') {
          await refreshSentinelMaster(timeout: timeout);
          _emitEvent(RedisEvent(
            type: RedisEventType.commandRetry,
            command: commandForError,
            attempt: attempt,
            error: mapped,
          ));
          attempt++;
          continue;
        }
        if (policy == null ||
            !policy.canRetry(mapped, attempt, commandForError)) {
          _emitEvent(RedisEvent(
            type: RedisEventType.commandError,
            command: commandForError,
            duration: sw.elapsed,
            error: mapped,
          ));
          throw mapped;
        }
        _emitEvent(RedisEvent(
          type: RedisEventType.commandRetry,
          command: commandForError,
          attempt: attempt,
          error: mapped,
        ));
        await Future<void>.delayed(policy.nextDelay(attempt, _retryRandom));
        attempt++;
      }
    }
  }

  /// send pipeline on the main connection using a single batched write.
  Future<List<dynamic>> sendPipeline(
    List<List<String>> commands, {
    Duration? timeout,
    int? batchSize,
  }) async {
    if (commands.isEmpty) {
      return <dynamic>[];
    }
    final effectiveBatchSize = batchSize ?? option.pipelineBatchSize;
    if (effectiveBatchSize <= 0) {
      throw ArgumentError.value(
        effectiveBatchSize,
        'batchSize',
        'must be greater than 0',
      );
    }
    if (commands.length <= effectiveBatchSize) {
      return connection.sendPipeline(commands, timeout: timeout);
    }

    final out = <dynamic>[];
    for (var start = 0; start < commands.length; start += effectiveBatchSize) {
      final end = min(start + effectiveBatchSize, commands.length);
      final batch = commands.sublist(start, end);
      out.addAll(await connection.sendPipeline(batch, timeout: timeout));
    }
    return out;
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

  Future<void> _resubscribeActiveListeners() async {
    final listeners = List<RedisSubscriber>.from(connection.subscribeListeners);
    if (listeners.isEmpty) {
      redisClientType = RedisType.normal;
      return;
    }

    redisClientType = RedisType.subscriber;
    for (final listener in listeners) {
      final command = listener.isSharded
          ? <String>['SSUBSCRIBE', listener.channel]
          : listener.isPattern
              ? <String>['PSUBSCRIBE', listener.channel]
              : <String>['SUBSCRIBE', listener.channel];
      await connection.sendCommand(command);
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

  /// Set binary value.
  Future<void> setBuffer(
    String key,
    Uint8List value, [
    String? option,
    dynamic optionValue,
  ]) async {
    final command = <Object?>['SET', prefixedKey(key), value];
    if (option != null && optionValue != null) {
      command.addAll(<Object?>[option.toUpperCase(), optionValue.toString()]);
    }
    final val = await sendBufferCommand(command) as String?;
    if (!RedisResponse.ok(val)) {
      throw RedisProtocolError('SET expected OK but got: $val');
    }
  }

  /// Get binary value.
  Future<Uint8List?> getBuffer(String key) async {
    return await sendBufferCommand(<Object?>['GET', prefixedKey(key)])
        as Uint8List?;
  }

  List<String> _commandSnapshot(List<Object?> commandList) {
    return commandList
        .map(
          (part) => switch (part) {
            final Uint8List bytes => '<bytes:${bytes.length}>',
            null => 'null',
            _ => part.toString(),
          },
        )
        .toList(growable: false);
  }

  Future<dynamic> _sendRedirectedCommand(
    List<String> commandList,
    RedisError redirect, {
    Duration? timeout,
  }) async {
    final redirectConnection = _clusterConnectionForRedirect(redirect);
    if (redirect is RedisAskError) {
      await redirectConnection
          .sendCommand(<String>['ASKING'], timeout: timeout);
    }
    return redirectConnection.sendCommand(commandList, timeout: timeout);
  }

  Future<dynamic> _sendRedirectedBufferCommand(
    List<Object?> commandList,
    RedisError redirect, {
    Duration? timeout,
  }) async {
    final redirectConnection = _clusterConnectionForRedirect(redirect);
    if (redirect is RedisAskError) {
      await redirectConnection
          .sendCommand(<String>['ASKING'], timeout: timeout);
    }
    return redirectConnection.sendBufferCommand(commandList, timeout: timeout);
  }

  RedisConnection _clusterConnectionForRedirect(RedisError redirect) {
    final host = switch (redirect) {
      final RedisMovedError moved => moved.host,
      final RedisAskError ask => ask.host,
      _ => throw ArgumentError('Redirect error expected'),
    };
    final port = switch (redirect) {
      final RedisMovedError moved => moved.port,
      final RedisAskError ask => ask.port,
      _ => throw ArgumentError('Redirect error expected'),
    };
    final endpoint = '$host:$port';
    return _clusterConnectionForEndpoint(endpoint);
  }

  /// Refresh cluster slot cache from `CLUSTER SLOTS`.
  Future<void> refreshClusterSlots({Duration? timeout}) async {
    if (!option.enableClusterMode) return;

    dynamic result;
    try {
      result = await connection.sendCommand(
        <String>['CLUSTER', 'SLOTS'],
        timeout: timeout,
      );
    } catch (_) {
      if (_clusterConnections.isEmpty) return;
      for (final clusterConnection in _clusterConnections.values) {
        try {
          result = await clusterConnection.sendCommand(
            <String>['CLUSTER', 'SLOTS'],
            timeout: timeout,
          );
          break;
        } catch (_) {}
      }
      if (result == null) return;
    }

    final parsed = _parseClusterSlots(result);
    if (parsed.isEmpty) return;
    _clusterSlotToEndpoint
      ..clear()
      ..addAll(parsed);
    _clusterSlotsLastRefreshAt = DateTime.now();
  }

  /// Resolve current master from Sentinel and update active connection target.
  Future<bool> refreshSentinelMaster({Duration? timeout}) async {
    if (!option.enableSentinelMode) return false;
    final masterName = option.sentinelMasterName;
    if (masterName == null || masterName.isEmpty || option.sentinels.isEmpty) {
      throw RedisProtocolError(
        'Sentinel mode requires sentinelMasterName and sentinels',
      );
    }

    _emitEvent(RedisEvent(
      type: RedisEventType.sentinelResolveStart,
      endpoint: _currentEndpoint(),
    ));

    Object? lastError;
    for (final sentinel in option.sentinels) {
      RedisConnection? sentinelConnection;
      try {
        final sentinelOptions = RedisOptions(
          host: sentinel.host,
          port: sentinel.port,
          secure: option.secure,
          connectTimeout: option.connectTimeout,
          commandTimeout: timeout ?? option.commandTimeout,
          username: option.username,
          password: option.password,
          retryStrategy: option.retryStrategy,
          onError: option.onError,
          maxConnection: 1,
          idleTimeout: option.idleTimeout,
          protocolVersion: option.protocolVersion,
          maxClusterRedirects: option.maxClusterRedirects,
          onEvent: option.onEvent,
          pipelineBatchSize: option.pipelineBatchSize,
          maxPendingCommands: option.maxPendingCommands,
        );
        sentinelConnection = RedisConnection(sentinelOptions);
        final result = await sentinelConnection.sendCommand(<String>[
          'SENTINEL',
          'get-master-addr-by-name',
          masterName,
        ], timeout: timeout);

        if (result is List && result.length >= 2) {
          final host = result[0];
          final portRaw = result[1];
          final port = int.tryParse(portRaw.toString());
          if (host is String && host.isNotEmpty && port != null) {
            final oldEndpoint = _currentEndpoint();
            option.host = host;
            option.port = port;
            _sentinelLastResolveAt = DateTime.now();
            if (oldEndpoint != _currentEndpoint()) {
              await connection.reconnect(force: true);
            }
            _emitEvent(RedisEvent(
              type: RedisEventType.sentinelResolveSuccess,
              endpoint: _currentEndpoint(),
            ));
            return true;
          }
        }
      } catch (error) {
        lastError = error;
      } finally {
        if (sentinelConnection != null) {
          await sentinelConnection.disconnect();
        }
      }
    }

    _emitEvent(RedisEvent(
      type: RedisEventType.sentinelResolveFailure,
      endpoint: _currentEndpoint(),
      error: lastError,
    ));
    if (lastError != null) {
      throw RedisErrorMapper.map(lastError);
    }
    return false;
  }

  RedisClusterDiagnostics clusterDiagnostics() {
    final endpoints = _clusterConnections.keys.toList()..sort();
    return RedisClusterDiagnostics(
      enabled: option.enableClusterMode,
      knownNodeEndpoints: endpoints,
      knownSlotCount: _clusterSlotToEndpoint.length,
      lastRefreshedAt: _clusterSlotsLastRefreshAt,
    );
  }

  DateTime? sentinelLastResolvedAt() => _sentinelLastResolveAt;

  /// Warm cluster topology cache by loading slot map.
  /// Returns true if slots are available after refresh.
  Future<bool> warmClusterSlots({Duration? timeout}) async {
    await refreshClusterSlots(timeout: timeout);
    return _clusterSlotToEndpoint.isNotEmpty;
  }

  Future<dynamic> _sendClusterRoutedCommandIfPossible(
    List<String> commandList, {
    Duration? timeout,
  }) async {
    if (!option.enableClusterMode) {
      return null;
    }
    final plan = _routingPlanFromCommand(commandList);
    if (plan == null || plan.keys.isEmpty) return null;
    _enforceSingleSlotIfNeeded(plan);
    if (_clusterSlotToEndpoint.isEmpty) {
      await refreshClusterSlots(timeout: timeout);
    }
    final slot = keySlot(plan.keys.first);
    final endpoint = _clusterSlotToEndpoint[slot];
    if (endpoint == null) return null;
    return _clusterConnectionForEndpoint(endpoint).sendCommand(
      commandList,
      timeout: timeout,
    );
  }

  Future<dynamic> _sendClusterRoutedBufferCommandIfPossible(
    List<Object?> commandList, {
    Duration? timeout,
  }) async {
    if (!option.enableClusterMode) {
      return null;
    }
    final plan = _routingPlanFromBufferCommand(commandList);
    if (plan == null || plan.keys.isEmpty) return null;
    _enforceSingleSlotIfNeeded(plan);
    if (_clusterSlotToEndpoint.isEmpty) {
      await refreshClusterSlots(timeout: timeout);
    }
    final slot = keySlot(plan.keys.first);
    final endpoint = _clusterSlotToEndpoint[slot];
    if (endpoint == null) return null;
    return _clusterConnectionForEndpoint(endpoint).sendBufferCommand(
      commandList,
      timeout: timeout,
    );
  }

  RedisConnection _clusterConnectionForEndpoint(String endpoint) {
    final existing = _clusterConnections[endpoint];
    if (existing != null) {
      return existing;
    }
    final separatorIndex = endpoint.lastIndexOf(':');
    if (separatorIndex <= 0 || separatorIndex == endpoint.length - 1) {
      throw ArgumentError('Invalid endpoint: $endpoint');
    }
    final host = endpoint.substring(0, separatorIndex);
    final port = int.parse(endpoint.substring(separatorIndex + 1));
    final options = RedisOptions(
      keyPrefix: option.keyPrefix,
      host: host,
      port: port,
      secure: option.secure,
      connectTimeout: option.connectTimeout,
      commandTimeout: option.commandTimeout,
      username: option.username,
      password: option.password,
      db: option.db,
      retryStrategy: option.retryStrategy,
      retryPolicy: option.retryPolicy,
      onError: option.onError,
      maxConnection: option.maxConnection,
      idleTimeout: option.idleTimeout,
      protocolVersion: option.protocolVersion,
      enableClusterMode: option.enableClusterMode,
      maxClusterRedirects: option.maxClusterRedirects,
      onEvent: option.onEvent,
      pipelineBatchSize: option.pipelineBatchSize,
      maxPendingCommands: option.maxPendingCommands,
    );
    final created = RedisConnection(options);
    _clusterConnections[endpoint] = created;
    return created;
  }

  Map<int, String> _parseClusterSlots(dynamic result) {
    if (result is! List) return const <int, String>{};
    final slots = <int, String>{};
    for (final entry in result) {
      if (entry is! List || entry.length < 3) continue;
      final start = entry[0];
      final end = entry[1];
      final primary = entry[2];
      if (start is! int || end is! int) continue;
      if (primary is! List || primary.length < 2) continue;
      final host = primary[0];
      final port = primary[1];
      if (host is! String || port is! int) continue;
      final endpoint = '$host:$port';
      for (var slot = start; slot <= end; slot++) {
        slots[slot] = endpoint;
      }
    }
    return slots;
  }

  static const Set<String> _singleKeyCommands = <String>{
    'GET',
    'SET',
    'DEL',
    'EXISTS',
    'HGET',
    'HSET',
    'HMGET',
    'LPUSH',
    'RPUSH',
    'LRANGE',
    'SADD',
    'SMEMBERS',
    'ZADD',
    'ZRANGE',
    'JSON.GET',
    'JSON.SET',
    'XADD',
    'XRANGE',
    'XREVRANGE',
    'XLEN',
    'XTRIM',
    'XDEL',
    'XACK',
    'XPENDING',
    'XAUTOCLAIM',
    'XCLAIM',
    'GETDEL',
    'GETEX',
    'GETSET',
    'INCR',
    'INCRBY',
    'DECR',
    'DECRBY',
    'APPEND',
    'STRLEN',
    'LLEN',
    'LPOP',
    'RPOP',
    'SPOP',
    'SCARD',
    'SISMEMBER',
    'ZCARD',
    'ZSCORE',
    'ZRANK',
    'ZREVRANK',
    'HDEL',
    'HLEN',
    'HEXISTS',
    'HGETALL',
    'HKEYS',
    'HVALS',
    'HINCRBY',
    'HINCRBYFLOAT',
    'EXPIRE',
    'PEXPIRE',
    'TTL',
    'PTTL',
    'PERSIST',
    'TYPE',
    'UNLINK',
    'DUMP',
    'RESTORE',
    'RENAMENX',
    'PFADD',
    'PFMERGE',
    'SSCAN',
    'HSCAN',
    'ZSCAN',
  };

  static const Set<String> _singleKeyCommandsKeyAt2 = <String>{
    'OBJECT',
    'XGROUP',
    'XINFO',
  };

  static const Set<String> _multiKeyCommandsSingleSlot = <String>{
    'MGET',
    'DEL',
    'EXISTS',
    'MSET',
    'MSETNX',
  };

  _ClusterRoutingPlan? _routingPlanFromCommand(List<String> commandList) {
    if (commandList.length < 2) return null;
    final command = commandList.first.toUpperCase();
    if (command == 'EVAL' ||
        command == 'EVALSHA' ||
        command == 'EVAL_RO' ||
        command == 'EVALSHA_RO') {
      if (commandList.length < 4) return null;
      final keyCount = int.tryParse(commandList[2]) ?? 0;
      if (keyCount <= 0) {
        return const _ClusterRoutingPlan(
          keys: <String>[],
          requiresSingleSlot: false,
        );
      }
      final end = 3 + keyCount;
      if (commandList.length < end) return null;
      return _ClusterRoutingPlan(
        keys: commandList.sublist(3, end),
        requiresSingleSlot: true,
      );
    }
    if (_singleKeyCommands.contains(command)) {
      return _ClusterRoutingPlan(
        keys: <String>[commandList[1]],
        requiresSingleSlot: true,
      );
    }
    if (_singleKeyCommandsKeyAt2.contains(command)) {
      if (commandList.length < 3) return null;
      return _ClusterRoutingPlan(
        keys: <String>[commandList[2]],
        requiresSingleSlot: true,
      );
    }
    if (_multiKeyCommandsSingleSlot.contains(command)) {
      if (command == 'MSET' || command == 'MSETNX') {
        final keys = <String>[];
        for (var i = 1; i < commandList.length; i += 2) {
          keys.add(commandList[i]);
        }
        return _ClusterRoutingPlan(keys: keys, requiresSingleSlot: true);
      }
      return _ClusterRoutingPlan(
        keys: commandList.sublist(1),
        requiresSingleSlot: true,
      );
    }
    return null;
  }

  _ClusterRoutingPlan? _routingPlanFromBufferCommand(
      List<Object?> commandList) {
    if (commandList.length < 2) return null;
    final command = commandList.first;
    if (command is! String) return null;
    final routeCommand = command.toUpperCase();
    if (!_singleKeyCommands.contains(routeCommand)) return null;
    final key = commandList[1];
    if (key is! String) return null;
    return _ClusterRoutingPlan(
      keys: <String>[key],
      requiresSingleSlot: true,
    );
  }

  void _enforceSingleSlotIfNeeded(_ClusterRoutingPlan plan) {
    if (!plan.requiresSingleSlot || plan.keys.length < 2) return;
    final expectedSlot = keySlot(plan.keys.first);
    for (final key in plan.keys.skip(1)) {
      if (keySlot(key) != expectedSlot) {
        throw RedisProtocolError(
          'CROSSSLOT Keys in request do not hash to the same slot',
        );
      }
    }
  }

  Future<void> _ensureSentinelReady() async {
    if (!option.enableSentinelMode) return;
    if (connection.status == RedisConnectionStatus.connected) return;
    await refreshSentinelMaster();
  }

  String _currentEndpoint() => '${option.host}:${option.port}';

  void _emitEvent(RedisEvent event) {
    final cb = option.onEvent;
    if (cb != null) {
      cb(event);
    }
  }

  /// Redis cluster hash slot for a key, honoring hashtag routing (`{...}`).
  int keySlot(String key) {
    final tag = _extractHashTag(key);
    final bytes = utf8.encode(tag ?? key);
    final crc = _crc16(bytes);
    return crc % 16384;
  }

  String? _extractHashTag(String key) {
    final start = key.indexOf('{');
    if (start == -1 || start == key.length - 1) return null;
    final end = key.indexOf('}', start + 1);
    if (end == -1 || end == start + 1) return null;
    return key.substring(start + 1, end);
  }

  int _crc16(List<int> data) {
    var crc = 0;
    for (final byte in data) {
      crc ^= (byte & 0xFF) << 8;
      for (var i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc & 0xFFFF;
  }

  int _toInt(dynamic value, {required String command}) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) {
        return parsed;
      }
    }
    throw RedisProtocolError('Unexpected response for $command: $value');
  }

  Stream<String> _scanValues({
    required String command,
    required String? key,
    required int count,
    String? match,
  }) async* {
    await for (final values in _scanChunkValues(
      command: command,
      key: key,
      match: match,
      count: count,
    )) {
      for (final value in values) {
        yield value;
      }
    }
  }

  Stream<List<String>> _scanChunkValues({
    required String command,
    required String? key,
    required int count,
    String? match,
  }) async* {
    var cursor = '0';
    do {
      final query = <String>[
        command,
        if (key != null) key,
        cursor,
        if (match != null) ...<String>['MATCH', match],
        ...<String>['COUNT', '$count'],
      ];
      final result = await sendCommand(query);
      final parsed = _parseScanResponse(result, command: command);
      cursor = parsed.$1;
      yield parsed.$2;
    } while (cursor != '0');
  }

  (String, List<String>) _parseScanResponse(dynamic result,
      {required String command}) {
    if (result is! List || result.length != 2) {
      throw RedisProtocolError(
          'Unexpected response for $command: ${result.runtimeType}');
    }
    final cursor = result[0];
    final values = result[1];
    if (cursor is! String || values is! List) {
      throw RedisProtocolError(
          'Unexpected response for $command: ${result.runtimeType}');
    }
    return (cursor, values.cast<String>());
  }
}
