import 'dart:async';
import 'dart:collection';
import 'dart:convert';
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
    required this.rawReply,
  });

  final List<String> command;
  final Completer<dynamic> completer;
  final bool rawReply;
  Timer? timer;

  void dispose() {
    timer?.cancel();
    timer = null;
  }
}

class RedisConnection {
  RedisConnection([RedisOptions? opt]) {
    option = (opt ?? defaultRedisOptions()).clone();
  }

  /// Redis option
  late RedisOptions option;

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
  int get pendingCount => _pendingResponses.length;

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
  Future<void> Function()? onReconnect;

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
    _shouldReconnect = true;
    _shouldThrowErrorOnConnection = true;
    _emitEvent(RedisEvent(
      type: RedisEventType.connectStart,
      endpoint: '${option.host}:${option.port}',
    ));
    await _connectGuarded(delayOnFailure: true);
  }

  /// Force reconnection, optionally after host/port has changed in options.
  Future<void> reconnect({bool force = false}) async {
    _shouldReconnect = true;
    _shouldThrowErrorOnConnection = true;
    if (force) {
      _setDisconnectedState();
    }
    _emitEvent(RedisEvent(
      type: RedisEventType.reconnectAttempt,
      endpoint: '${option.host}:${option.port}',
    ));
    await _connectGuarded(delayOnFailure: false);
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
    _stream =
        _redisSocket?.transform<dynamic>(BufferedRedisResponseTransformer());

    _subscription = _stream?.listen(
      (dynamic packet) {
        try {
          final packetPayload = packet is RedisPushData ? packet.items : packet;
          if (packetPayload is List) {
            final textPacket = _normalizeReply(packetPayload, rawReply: false);
            if (textPacket is List &&
                textPacket.isNotEmpty &&
                textPacket[0] is String) {
              final type = textPacket[0] as String;
              final pmessage = type == 'pmessage';
              final rmessage = type == 'message';
              final smessage = type == 'smessage';
              final unsubscribe = type == 'unsubscribe';
              final punsubscribe = type == 'punsubscribe';
              final sunsubscribe = type == 'sunsubscribe';
              final isMessage = rmessage || pmessage || smessage;
              if (isMessage &&
                  ((pmessage && textPacket.length >= 4) ||
                      (smessage && textPacket.length >= 3) ||
                      (!pmessage && !smessage && textPacket.length >= 3))) {
                final channel = textPacket[pmessage ? 2 : 1] as String;
                final message = textPacket[pmessage ? 3 : 2] as String?;
                final cb = _findSubscribeListener(
                  pmessage ? textPacket[1] as String : channel,
                  isPattern: pmessage,
                  isSharded: smessage,
                );
                cb?.onMessage?.call(channel, message);
              }
              if (unsubscribe && textPacket.length >= 2) {
                removeSubscriber(textPacket[1] as String,
                    isPattern: false, isSharded: false);
              }
              if (punsubscribe && textPacket.length >= 2) {
                removeSubscriber(textPacket[1] as String,
                    isPattern: true, isSharded: false);
              }
              if (sunsubscribe && textPacket.length >= 2) {
                removeSubscriber(textPacket[1] as String,
                    isPattern: false, isSharded: true);
              }
            }
          }
        } catch (e) {
          _throwSafeError(
            RedisProtocolError(
              'Failed to handle packet: $packet',
              cause: e,
            ),
          );
        }

        // Do not consume unsolicited pushes as command responses.
        // RESP3 subscribe/unsubscribe acknowledgements can arrive as pushes and
        // must still complete the pending command future.
        if (!_isUnsolicitedPacket(packet)) {
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
    _emitEvent(RedisEvent(
      type: RedisEventType.disconnect,
      endpoint: '${option.host}:${option.port}',
    ));
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
    _emitEvent(RedisEvent(
      type: RedisEventType.disconnect,
      endpoint: '${option.host}:${option.port}',
    ));
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
        _emitEvent(RedisEvent(
          type: RedisEventType.reconnectAttempt,
          endpoint: '${option.host}:${option.port}',
          attempt: _totalRetry,
        ));
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
    List<Object?> commandList, {
    Duration? timeout,
    bool rawReply = false,
    List<String>? commandForError,
    bool allowWhileConnecting = false,
  }) async {
    final canSendWhileConnecting = allowWhileConnecting &&
        status == RedisConnectionStatus.connecting &&
        _redisSocket != null;
    if (!canSendWhileConnecting &&
        (status != RedisConnectionStatus.connected || _redisSocket == null)) {
      await connect();
    }

    final socket = _redisSocket;
    if (socket == null ||
        (status != RedisConnectionStatus.connected &&
            !canSendWhileConnecting)) {
      throw RedisConnectionError('Redis connection is not available');
    }

    final pending = _registerPending(
      commandForError ?? _commandSnapshot(commandList),
      timeout: timeout,
      rawReply: rawReply,
    );
    try {
      socket.add(_encoder.encode(commandList));
    } catch (error) {
      _pendingResponses.remove(pending);
      pending.dispose();
      throw RedisErrorMapper.map(
        error,
        command: commandForError ?? _commandSnapshot(commandList),
      );
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
      final value = await _sendCommand(
        commandList,
        timeout: timeout,
        commandForError: List<String>.from(commandList),
      );
      return value;
    } finally {
      _inFlight--;
    }
  }

  Future<dynamic> sendBufferCommand(
    List<Object?> commandList, {
    Duration? timeout,
  }) async {
    _inFlight++;
    try {
      final value = await _sendCommand(
        commandList,
        timeout: timeout,
        rawReply: true,
      );
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

      final maxPending = option.maxPendingCommands;
      if (_pendingResponses.length + commands.length > maxPending) {
        throw RedisConnectionError(
          'Backpressure: too many pending commands '
          '(${_pendingResponses.length + commands.length}/$maxPending)',
        );
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
      {required bool isPattern, required bool isSharded}) {
    final cb = subscribeListeners.firstWhereOrNull(
      (e) =>
          e.channel == channel &&
          e.isPattern == isPattern &&
          e.isSharded == isSharded,
    );
    return cb;
  }

  void addSubscriber(RedisSubscriber subscriber) {
    removeSubscriber(
      subscriber.channel,
      isPattern: subscriber.isPattern,
      isSharded: subscriber.isSharded,
    );
    subscribeListeners.add(subscriber);
  }

  void removeSubscriber(String channel,
      {required bool isPattern, required bool isSharded}) {
    subscribeListeners.removeWhere(
      (listener) =>
          listener.channel == channel &&
          listener.isPattern == isPattern &&
          listener.isSharded == isSharded,
    );
  }

  void removeAllSubscribers(
      {required bool isPattern, required bool isSharded}) {
    subscribeListeners.removeWhere((listener) =>
        listener.isPattern == isPattern && listener.isSharded == isSharded);
  }

  /// Login to redis
  Future<dynamic> _login() async {
    final username = option.username;
    final password = option.password;
    if (password != null) {
      final commands = username != null
          ? <String>['AUTH', username, password]
          : <String>['AUTH', password];
      final result =
          await _sendCommand(commands, allowWhileConnecting: true) as String?;
      if (!RedisResponse.ok(result)) {
        throw RedisAuthError(result ?? 'AUTH failed', command: commands);
      }
      return result;
    }
  }

  Future<dynamic> _hello() async {
    final protocolVersion = option.protocolVersion;
    if (protocolVersion == 2) {
      return null;
    }

    final command = <String>['HELLO', '$protocolVersion'];
    final password = option.password;
    if (password != null) {
      command.addAll(<String>[
        'AUTH',
        option.username ?? 'default',
        password,
      ]);
    }

    final result = await _sendCommand(command, allowWhileConnecting: true);
    return result;
  }

  /// Select database index
  Future<dynamic> _selectDatabaseIndex() async {
    final command = <String>['SELECT', option.db.toString()];
    final result =
        await _sendCommand(command, allowWhileConnecting: true) as String?;
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
    }
  }

  Future<void> _connectWithOptionalDelay({required bool delayOnFailure}) async {
    try {
      status = RedisConnectionStatus.connecting;

      /// Create new socket if not exist
      if (_redisSocket == null) {
        if (option.secure) {
          _redisSocket = await SecureSocket.connect(
            option.host,
            option.port,
            timeout: option.connectTimeout,
            context: option.tlsContext,
            onBadCertificate: option.onBadCertificate,
            supportedProtocols: option.supportedProtocols,
          );
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

      await _hello();

      /// If username is provided, we need to login before calling other commands
      if (option.protocolVersion == 2) {
        await _login();
      }

      /// Select database index
      await _selectDatabaseIndex();

      /// Set status as connected after the handshake has succeeded.
      status = RedisConnectionStatus.connected;
      _emitEvent(RedisEvent(
        type: RedisEventType.connectSuccess,
        endpoint: '${option.host}:${option.port}',
      ));

      /// Once socket is connect reset retry count to zero
      _totalRetry = 0;
      final reconnectHook = onReconnect;
      if (reconnectHook != null) {
        await reconnectHook();
      }
    } catch (error) {
      _setDisconnectedState();
      final mapped = RedisErrorMapper.map(error);
      _throwSafeError(mapped);
      if (delayOnFailure) {
        final retryAttempt = max(_totalRetry, 1);
        final retryDelay = option.retryStrategy?.call(retryAttempt) ??
            Duration(milliseconds: min(retryAttempt * 50, 2000));
        await Future<void>.delayed(retryDelay);
      }
      throw mapped;
    }
  }

  void _emitEvent(RedisEvent event) {
    final cb = option.onEvent;
    if (cb != null) {
      cb(event);
    }
  }

  bool _isUnsolicitedPacket(dynamic packet) {
    final type = _packetType(packet);
    if (type == null) {
      return false;
    }
    return _isUnsolicitedPushType(type);
  }

  bool _isUnsolicitedPushType(String type) {
    return type == 'message' ||
        type == 'pmessage' ||
        type == 'smessage' ||
        type == 'invalidate';
  }

  String? _packetType(dynamic packet) {
    if (packet is RedisPushData) {
      if (packet.items.isEmpty) return null;
      final first = packet.items.first;
      if (first is RedisBulkData) {
        return utf8.decode(first.bytes);
      }
      if (first is String) return first;
      return null;
    }
    if (packet is! List || packet.isEmpty) {
      return null;
    }
    final first = packet[0];
    if (first is String) {
      return first;
    }
    if (first is RedisBulkData) {
      return utf8.decode(first.bytes);
    }
    return null;
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

    try {
      pending.completer.complete(
        _normalizeReply(packet, rawReply: pending.rawReply),
      );
    } catch (error) {
      pending.completer.completeError(
        RedisErrorMapper.map(error, command: pending.command),
      );
    }
  }

  _PendingCommand _registerPending(
    List<String> command, {
    Duration? timeout,
    bool rawReply = false,
  }) {
    final maxPending = option.maxPendingCommands;
    if (_pendingResponses.length >= maxPending) {
      throw RedisConnectionError(
        'Backpressure: too many pending commands '
        '(${_pendingResponses.length}/$maxPending)',
        command: command,
      );
    }
    final completer = Completer<dynamic>();
    final entry = _PendingCommand(
      command: List<String>.from(command),
      completer: completer,
      rawReply: rawReply,
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

  dynamic _normalizeReply(dynamic packet, {required bool rawReply}) {
    if (packet is RedisBulkData) {
      if (rawReply) {
        return packet.bytes;
      }
      return utf8.decode(packet.bytes);
    }
    if (packet is RedisPushData) {
      return RedisPushData(
        packet.items
            .map((item) => _normalizeReply(item, rawReply: rawReply))
            .toList(),
      );
    }
    if (packet is RedisAttributedData) {
      // Keep response compatibility for existing APIs by returning the wrapped data.
      return _normalizeReply(packet.data, rawReply: rawReply);
    }
    if (packet is Map<dynamic, dynamic>) {
      return packet.map(
        (key, value) => MapEntry(
          _normalizeReply(key, rawReply: rawReply),
          _normalizeReply(value, rawReply: rawReply),
        ),
      );
    }
    if (packet is Set<dynamic>) {
      return packet
          .map((item) => _normalizeReply(item, rawReply: rawReply))
          .toSet();
    }
    if (packet is List<dynamic>) {
      return packet
          .map((item) => _normalizeReply(item, rawReply: rawReply))
          .toList();
    }
    return packet;
  }
}
