import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_connection_pool.dart';
import 'package:ioredis/src/redis_multi_command.dart';

class Redis {
  Redis([RedisOptions? opt]) {
    option = (opt ?? defaultRedisOptions()).clone();
    connection = RedisConnection(option);
    connection.onReconnect = _resubscribeActiveListeners;
    pool = RedisConnectionPool(option, connection);
  }
  late RedisConnection connection;

  late RedisOptions option;

  late RedisConnectionPool pool;

  /// Redis client type
  /// subscriber, publisher or normal set and get
  RedisType redisClientType = RedisType.normal;

  final Random _retryRandom = Random();
  RedisConnection? _transactionConnection;
  Future<void> _transactionTail = Future<void>.value();

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
    final txConnection = _transactionConnection;
    _transactionConnection = null;
    if (txConnection != null) {
      await txConnection.disconnect();
    }
    redisClientType = RedisType.normal;
  }

  /// Duplicate new redis connection
  Redis duplicate() {
    return Redis(option.clone());
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

  /// Start an optimistic transaction wrapper on a dedicated connection.
  Future<RedisOptimisticTransaction> watch(List<String> keys) async {
    return RedisOptimisticTransaction.start(
      option: option.clone(),
      keys: _setPrefixInKeys(keys),
    );
  }

  /// Send UNWATCH on the current client connection.
  Future<void> unwatch() async {
    await sendCommand(<String>['UNWATCH']);
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
    if (result is Set) {
      return result.map((item) => item as String).toList();
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
      if (withScores &&
          result.isNotEmpty &&
          result.every(
              (item) => item is List && item.length == 2 && item[0] != null)) {
        final values = <String>[];
        for (final item in result.cast<List<dynamic>>()) {
          values.add(item[0].toString());
          values.add(item[1].toString());
        }
        return values;
      }
      return result.map((item) => item.toString()).toList();
    }
    if (result is Map && withScores) {
      final values = <String>[];
      for (final entry in result.entries) {
        values.add(entry.key.toString());
        values.add(entry.value.toString());
      }
      return values;
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
    final policy = retryPolicy ?? option.retryPolicy;
    var attempt = 1;
    final sw = Stopwatch()..start();

    while (true) {
      try {
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
    final policy = retryPolicy ?? option.retryPolicy;
    final commandForError = _commandSnapshot(commandList);
    var attempt = 1;
    final sw = Stopwatch()..start();

    while (true) {
      try {
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
    RedisRetryPolicy? retryPolicy,
  }) async {
    if (commands.isEmpty) {
      return <dynamic>[];
    }
    final policy = retryPolicy ?? option.retryPolicy;
    final sw = Stopwatch()..start();
    final commandForEvent = <String>['PIPELINE', commands.length.toString()];
    var attempt = 1;
    final effectiveBatchSize = batchSize ?? option.pipelineBatchSize;
    if (effectiveBatchSize <= 0) {
      throw ArgumentError.value(
        effectiveBatchSize,
        'batchSize',
        'must be greater than 0',
      );
    }

    while (true) {
      try {
        if (commands.length <= effectiveBatchSize) {
          final result =
              await connection.sendPipeline(commands, timeout: timeout);
          _emitEvent(RedisEvent(
            type: RedisEventType.commandSuccess,
            command: commandForEvent,
            duration: sw.elapsed,
          ));
          return result;
        }

        final out = <dynamic>[];
        for (var start = 0;
            start < commands.length;
            start += effectiveBatchSize) {
          final end = min(start + effectiveBatchSize, commands.length);
          final batch = commands.sublist(start, end);
          out.addAll(await connection.sendPipeline(batch, timeout: timeout));
        }
        _emitEvent(RedisEvent(
          type: RedisEventType.commandSuccess,
          command: commandForEvent,
          duration: sw.elapsed,
        ));
        return out;
      } catch (error) {
        final mapped = RedisErrorMapper.map(error, command: commandForEvent);
        if (policy == null ||
            !policy.canRetry(mapped, attempt, commandForEvent)) {
          _emitEvent(RedisEvent(
            type: RedisEventType.commandError,
            command: commandForEvent,
            duration: sw.elapsed,
            error: mapped,
          ));
          throw mapped;
        }
        _emitEvent(RedisEvent(
          type: RedisEventType.commandRetry,
          command: commandForEvent,
          attempt: attempt,
          error: mapped,
        ));
        await Future<void>.delayed(policy.nextDelay(attempt, _retryRandom));
        attempt++;
      }
    }
  }

  /// Execute MULTI/EXEC commands on a reusable dedicated transaction connection.
  Future<List<dynamic>> executeMulti(List<List<String>> commands) {
    if (commands.isEmpty) {
      return Future<List<dynamic>>.value(<dynamic>[]);
    }
    return _withTransactionConnection<List<dynamic>>((conn) async {
      var multiStarted = false;
      var execSent = false;
      try {
        await conn.sendCommand(<String>['MULTI']);
        multiStarted = true;
        for (final command in commands) {
          await conn.sendCommand(command);
        }
        execSent = true;
        final result = await conn.sendCommand(<String>['EXEC']);
        if (result is List<dynamic>) {
          return result;
        }
        if (result == null) {
          return <dynamic>[];
        }
        throw StateError('Unexpected response for EXEC: ${result.runtimeType}');
      } catch (_) {
        if (multiStarted && !execSent) {
          try {
            await conn.sendCommand(<String>['DISCARD']);
          } catch (_) {}
        }
        rethrow;
      }
    });
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

  Future<T> _withTransactionConnection<T>(
    Future<T> Function(RedisConnection connection) work,
  ) {
    final completer = Completer<T>();
    _transactionTail = _transactionTail.catchError((_) {}).then((_) async {
      final conn = _transactionConnection ??= RedisConnection(option);
      try {
        completer.complete(await work(conn));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _emitEvent(RedisEvent event) {
    final cb = option.onEvent;
    if (cb != null) {
      cb(event);
    }
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
