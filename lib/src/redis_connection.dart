import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:ioredis/src/redis_response.dart';
import 'package:ioredis/src/transformer.dart';

class _PendingCommand {
  _PendingCommand({
    required this.command,
    required this.completer,
  });

  final List<String> command;
  final Completer<dynamic> completer;
  Timer? timer;

  void dispose() {
    timer?.cancel();
    timer = null;
  }
}

class RedisConnection {
  RedisConnection([RedisOptions? opt]) {
    if (opt != null) {
      option = opt;
    }
  }

  /// Redis option
  RedisOptions option = defaultRedisOptions;

  /// Current status of redis connection
  RedisConnectionStatus status = RedisConnectionStatus.disconnected;

  /// Current active socket;
  Socket? _redisSocket;

  /// Current active socket;
  Stream<dynamic>? _stream;

  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? _subscription;

  /// Total retry count
  int _totalRetry = 0;

  /// Queue of pending command responses.
  final Queue<_PendingCommand> _pendingResponses = Queue<_PendingCommand>();

  /// Serializer to send the command to redis
  final RedisMessageEncoder _encoder = RedisMessageEncoder();

  /// To check whether it should reconnect
  /// when socket is manually disconnect.
  bool _shouldReconnect = true;

  /// should not throw when disconnect is called programmatically
  bool _shouldThrowErrorOnConnection = true;

  /// Number of in-flight commands on this connection.
  int _inFlight = 0;

  /// check connection is free
  bool get isBusy => _inFlight > 0;

  /// Listeners of subscribers
  final subscribeListeners = <RedisSubscriber>[];

  Future<void>? _connectFuture;

  bool _isReconnecting = false;

  /// Get current connection status
  String getStatus() => status.name;

  /// Set custom socket
  void setSocket(Socket socket) {
    _redisSocket = socket;
  }

  /// Connect to redis connection
  /// ```
  /// await redis.connect()
  /// ```
  Future<void> connect() async {
    await _connectGuarded(delayOnFailure: true);
  }

  Future<void> _connectGuarded({required bool delayOnFailure}) async {
    final pending = _connectFuture;
    if (pending != null) {
      await pending;
      return;
    }

    final connectFuture =
        _connectWithOptionalDelay(delayOnFailure: delayOnFailure);
    _connectFuture = connectFuture;
    try {
      await connectFuture;
    } finally {
      if (identical(_connectFuture, connectFuture)) {
        _connectFuture = null;
      }
    }
  }

  /// Listen response from redis and sent to completer or callback.
  /// onDone callback is used to listen for redis disconnect to reconnect.
  void _listenResponseFromRedis() {
    final existingSubscription = _subscription;
    if (existingSubscription != null) {
      unawaited(existingSubscription.cancel());
    }
    _stream = _redisSocket
        ?.transform<String>(transformer)
        .transform<dynamic>(BufferedRedisResponseTransformer());

    _subscription = _stream?.listen(
      (dynamic packet) {
        try {
          if (packet is List && packet.isNotEmpty && packet[0] is String) {
            final type = packet[0] as String;
            final pmessage = type == 'pmessage';
            final rmessage = type == 'message';
            final unsubscribe = type == 'unsubscribe';
            final punsubscribe = type == 'punsubscribe';
            final isMessage = rmessage || pmessage;
            if (isMessage &&
                ((pmessage && packet.length >= 4) ||
                    (!pmessage && packet.length >= 3))) {
              final channel = packet[pmessage ? 2 : 1] as String;
              final message = packet[pmessage ? 3 : 2] as String?;
              final cb = _findSubscribeListener(
                pmessage ? packet[1] as String : channel,
                isPattern: pmessage,
              );
              cb?.onMessage?.call(channel, message);
            }
            if (unsubscribe && packet.length >= 2) {
              removeSubscriber(packet[1] as String, isPattern: false);
            }
            if (punsubscribe && packet.length >= 2) {
              removeSubscriber(packet[1] as String, isPattern: true);
            }
          }
        } catch (e, st) {
          print('packet: $packet');
          print(e);
          print(st);
        }

        // Pub/Sub pushed messages are not command responses.
        if (!_isPubSubPush(packet)) {
          _completeNextPending(packet);
        }
      },
      onError: (Object error, StackTrace st) async {
        final mapped = RedisErrorMapper.map(error);
        _setDisconnectedState();
        _failAllPending(mapped);
        _throwSafeError(mapped);
        unawaited(_reconnect());
      },
      onDone: () async {
        final disconnected = RedisConnectionError('Redis disconnected');
        _setDisconnectedState();
        _failAllPending(disconnected);
        _throwSafeError(disconnected);
        unawaited(_reconnect());
      },
    );
  }

  /// Disconnect redis connection
  Future<void> disconnect() async {
    _shouldReconnect = false;
    _shouldThrowErrorOnConnection = false;
    status = RedisConnectionStatus.disconnected;
    _failAllPending(RedisConnectionError('Redis connection closed'));
    subscribeListeners.clear();
    final existingSubscription = _subscription;
    if (existingSubscription != null) {
      await existingSubscription.cancel();
      _subscription = null;
    }
    await _redisSocket?.close();
  }

  /// Disconnect redis connection
  void destroy() {
    _shouldReconnect = false;
    _shouldThrowErrorOnConnection = false;
    status = RedisConnectionStatus.disconnected;
    _failAllPending(RedisConnectionError('Redis connection destroyed'));
    subscribeListeners.clear();
    final existingSubscription = _subscription;
    if (existingSubscription != null) {
      unawaited(existingSubscription.cancel());
      _subscription = null;
    }
    _redisSocket?.destroy();
  }

  /// Handle connection reconnect
  Future<void> _reconnect() async {
    if (_isReconnecting || !_shouldReconnect) {
      return;
    }
    _isReconnecting = true;
    try {
      while (_shouldReconnect && status != RedisConnectionStatus.connected) {
        _totalRetry++;
        final retryDelay = option.retryStrategy?.call(_totalRetry) ??
            Duration(milliseconds: min(_totalRetry * 50, 2000));
        await Future<void>.delayed(retryDelay);
        try {
          await _connectGuarded(delayOnFailure: false);
        } on SocketException catch (_) {
          // Keep retrying in background.
        } catch (_) {
          // Keep retrying in background.
        }
      }
    } finally {
      _isReconnecting = false;
    }
  }

  /// Send redis command.
  Future<dynamic> _sendCommand(
    List<String> commandList, {
    Duration? timeout,
  }) async {
    if (status != RedisConnectionStatus.connected || _redisSocket == null) {
      await connect();
    }

    final socket = _redisSocket;
    if (socket == null || status != RedisConnectionStatus.connected) {
      throw RedisConnectionError('Redis connection is not available');
    }

    final pending = _registerPending(commandList, timeout: timeout);
    try {
      socket.add(_encoder.encode(commandList));
    } catch (error) {
      _pendingResponses.remove(pending);
      pending.dispose();
      throw RedisErrorMapper.map(error, command: commandList);
    }

    return pending.completer.future;
  }

  /// Send redis command.
  Future<dynamic> sendCommand(
    List<String> commandList, {
    Duration? timeout,
  }) async {
    _inFlight++;
    try {
      final value = await _sendCommand(commandList, timeout: timeout);
      return value;
    } finally {
      _inFlight--;
    }
  }

  /// Sends pipelined commands in a single socket write.
  Future<List<dynamic>> sendPipeline(
    List<List<String>> commands, {
    Duration? timeout,
  }) async {
    if (commands.isEmpty) {
      return <dynamic>[];
    }

    _inFlight += commands.length;
    try {
      if (status != RedisConnectionStatus.connected || _redisSocket == null) {
        await connect();
      }

      final socket = _redisSocket;
      if (socket == null || status != RedisConnectionStatus.connected) {
        throw RedisConnectionError('Redis connection is not available');
      }

      final pending = <_PendingCommand>[];
      final output = BytesBuilder(copy: false);
      for (final command in commands) {
        output.add(_encoder.encode(command));
        pending.add(_registerPending(command, timeout: timeout));
      }

      try {
        socket.add(output.takeBytes());
      } catch (error) {
        for (final item in pending) {
          _pendingResponses.remove(item);
          item.dispose();
          if (!item.completer.isCompleted) {
            item.completer.completeError(
              RedisErrorMapper.map(error, command: item.command),
            );
          }
        }
      }

      return Future.wait<dynamic>(
        pending.map((item) => item.completer.future),
      );
    } finally {
      _inFlight -= commands.length;
    }
  }

  /// Get subscribe listener callback related to the channel or pattern
  RedisSubscriber? _findSubscribeListener(String channel,
      {required bool isPattern}) {
    final cb = subscribeListeners.firstWhereOrNull(
      (e) => e.channel == channel && e.isPattern == isPattern,
    );
    return cb;
  }

  void addSubscriber(RedisSubscriber subscriber) {
    removeSubscriber(subscriber.channel, isPattern: subscriber.isPattern);
    subscribeListeners.add(subscriber);
  }

  void removeSubscriber(String channel, {required bool isPattern}) {
    subscribeListeners.removeWhere(
      (listener) =>
          listener.channel == channel && listener.isPattern == isPattern,
    );
  }

  void removeAllSubscribers({required bool isPattern}) {
    subscribeListeners
        .removeWhere((listener) => listener.isPattern == isPattern);
  }

  /// Login to redis
  Future<dynamic> _login() async {
    final username = option.username;
    final password = option.password;
    if (password != null) {
      final commands = username != null
          ? <String>['AUTH', username, password]
          : <String>['AUTH', password];
      final result = await _sendCommand(commands) as String?;
      if (!RedisResponse.ok(result)) {
        throw RedisAuthError(result ?? 'AUTH failed', command: commands);
      }
      return result;
    }
  }

  /// Select database index
  Future<dynamic> _selectDatabaseIndex() async {
    final command = <String>['SELECT', option.db.toString()];
    final result = await _sendCommand(command) as String?;
    if (!RedisResponse.ok(result)) {
      throw RedisCommandError('SELECT', result ?? 'SELECT failed',
          command: command);
    }
    return result;
  }

  /// Safely throw error
  /// If redis connection error,
  /// stop throwing error to prevent application crash.
  /// If onError is provided in redisOptions, it will be call to onError,
  /// else error will log safely.
  void _throwSafeError(dynamic err) {
    if (!_shouldThrowErrorOnConnection) return;
    final onError = option.onError;
    if (onError != null) {
      onError(err);
    } else {
      print(err);
    }
  }

  Future<void> _connectWithOptionalDelay({required bool delayOnFailure}) async {
    _totalRetry++;
    try {
      status = RedisConnectionStatus.connecting;

      /// Create new socket if not exist
      if (_redisSocket == null) {
        if (option.secure) {
          _redisSocket = await SecureSocket.connect(option.host, option.port,
              timeout: option.connectTimeout);
        } else {
          _redisSocket = await Socket.connect(option.host, option.port,
              timeout: option.connectTimeout);
        }
      }

      /// Setting socket option to tcp no delay
      /// If tcpNoDelay is enabled, the socket will not buffer data internally,
      /// but instead write each data chunk as an individual TCP packet.
      _redisSocket?.setOption(SocketOption.tcpNoDelay, true);

      /// listening for response
      _listenResponseFromRedis();

      /// Set status as connected
      status = RedisConnectionStatus.connected;

      /// Once socket is connect reset retry count to zero
      _totalRetry = 0;

      /// If username is provided, we need to login before calling other commands
      await _login();

      /// Select database index
      await _selectDatabaseIndex();
    } on SocketException catch (error) {
      _setDisconnectedState();
      final mapped = RedisConnectionError(error.message, cause: error);
      _throwSafeError(mapped);
      if (delayOnFailure) {
        final retryDelay = option.retryStrategy?.call(_totalRetry) ??
            Duration(milliseconds: min(_totalRetry * 50, 2000));
        await Future<void>.delayed(retryDelay);
      }
      throw mapped;
    }
  }

  bool _isPubSubPush(dynamic packet) {
    if (packet is! List || packet.isEmpty || packet[0] is! String) {
      return false;
    }
    final type = packet[0] as String;
    return type == 'message' || type == 'pmessage';
  }

  void _completeNextPending(dynamic packet) {
    if (_pendingResponses.isEmpty) {
      return;
    }
    final pending = _pendingResponses.removeFirst();
    pending.dispose();
    if (pending.completer.isCompleted) {
      return;
    }

    if (packet is RedisServerErrorReply) {
      pending.completer.completeError(
        RedisErrorMapper.fromServerError(packet.message,
            command: pending.command),
      );
      return;
    }

    pending.completer.complete(packet);
  }

  _PendingCommand _registerPending(
    List<String> command, {
    Duration? timeout,
  }) {
    final completer = Completer<dynamic>();
    final entry = _PendingCommand(
      command: List<String>.from(command),
      completer: completer,
    );

    final effectiveTimeout = timeout ?? option.commandTimeout;
    if (effectiveTimeout != null) {
      entry.timer = Timer(effectiveTimeout, () {
        final removed = _pendingResponses.remove(entry);
        if (!removed || entry.completer.isCompleted) {
          return;
        }

        entry.completer.completeError(
          RedisTimeoutError(timeout: effectiveTimeout, command: command),
        );
        entry.dispose();

        _setDisconnectedState();
        _failAllPending(
          RedisConnectionError(
            'Connection reset after command timeout',
          ),
        );
        unawaited(_reconnect());
      });
    }

    _pendingResponses.addLast(entry);
    return entry;
  }

  void _failAllPending(Object error) {
    while (_pendingResponses.isNotEmpty) {
      final pending = _pendingResponses.removeFirst();
      pending.dispose();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
  }

  void _setDisconnectedState() {
    status = RedisConnectionStatus.disconnected;
    final existingSubscription = _subscription;
    if (existingSubscription != null) {
      unawaited(existingSubscription.cancel());
    }
    _subscription = null;
    _redisSocket?.destroy();
    _redisSocket = null;
  }
}
