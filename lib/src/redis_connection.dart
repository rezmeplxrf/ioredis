import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:ioredis/ioredis.dart';
import 'package:ioredis/src/default.dart';
import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:ioredis/src/transformer.dart';

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

  /// Total retry count
  int _totalRetry = 0;

  /// Current complete to listen for the response from redis
  Completer<dynamic>? _completer;

  /// Serializer to send the command to redis
  final RedisMessageEncoder _encoder = RedisMessageEncoder();

  /// To check whether it should reconnect
  /// when socket is manually disconnect.
  bool _shouldReconnect = true;

  /// should not throw when disconnect is called programmatically
  bool _shouldThrowErrorOnConnection = true;

  /// check connection is free
  bool isBusy = false;

  /// Listeners of subscribers
  final subscribeListeners = <RedisSubscriber>[];

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
    _totalRetry++;
    try {
      status = RedisConnectionStatus.connecting;

      /// Create new socket if not exist
      if (_redisSocket == null) {
        if (option.secure == true) {
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
    } catch (error) {
      if (error is SocketException) {
        _throwSafeError(
          SocketException(error.message,
              address: InternetAddress(option.host), port: option.port),
        );
        status = RedisConnectionStatus.disconnected;

        /// If error is SocketException, need to reconnect
        await _reconnect();
      } else {
        /// rethrow application logic errors
        rethrow;
      }
    }
  }

  /// Listen response from redis and sent to completer ro callback.
  /// onDone callback is use to listen redis disconnect to reconnect
  /// Listen response from redis and sent to completer or callback.
  /// onDone callback is used to listen for redis disconnect to reconnect
  void _listenResponseFromRedis() {
    _stream = _redisSocket
        ?.transform<String>(transformer)
        .transform<dynamic>(redisResponseTransformer);

    _stream?.listen(
      (dynamic packet) {
        try {
          if (packet is List && packet.isNotEmpty) {
            final type = packet[0] as String;
            final pmessage = type == 'pmessage';
            final rmessage = type == 'message';
            final isMessage = rmessage || pmessage;
            if (isMessage && packet.length >= 3) {
              final channel = packet[pmessage ? 2 : 1] as String;
              final message = packet[pmessage ? 3 : 2] as String?;
              final cb = _findSubscribeListener(
                  pmessage ? packet[1] as String : channel);
              cb?.onMessage?.call(channel, message);
            }
          }
        } catch (e, st) {
          print('packet: $packet');
          print(e);
          print(st);
        } finally {
          _completer?.complete(packet);
          _completer = null;
        }
      },
      onDone: () async {
        _redisSocket?.destroy();
        _redisSocket = null;
        _throwSafeError(
          SocketException('Redis disconnected',
              address: InternetAddress(option.host), port: option.port),
        );
        await _reconnect();
      },
    );
  }

  /// Disconnect redis connection
  Future<void> disconnect() async {
    _shouldReconnect = false;
    _shouldThrowErrorOnConnection = false;
    await _redisSocket?.close();
  }

  /// Disconnect redis connection
  void destroy() {
    _shouldReconnect = false;
    _shouldThrowErrorOnConnection = false;
    _redisSocket?.destroy();
  }

  /// Handle connection reconnect
  Future<void> _reconnect() async {
    if (_shouldReconnect) {
      await Future<void>.delayed(option.retryStrategy!(_totalRetry));
      await connect();
    }
  }

  /// Send redis command
  /// ```
  /// await redis.sendCommand(['SET', 'foo', 'bar']);
  /// await redis.sendCommand(['GET', 'foo']);
  /// ```
  Future<dynamic> _sendCommand(List<String> commandList) async {
    try {
      if (status == RedisConnectionStatus.disconnected) {
        await connect();
      }
      // for the synchronous operations, execute one after another in a sequential manner
      // send new command only if the response is completed from redis
      while (true) {
        if (_completer == null || _completer?.isCompleted == true) {
          _completer = Completer<dynamic>();
          _redisSocket?.add(_encoder.encode(commandList));
          break;
        }
        await _completer?.future;
      }
      return await _completer?.future;
    } catch (error) {
      print(error);
      return null;
    }
  }

  /// Send redis command
  /// ```
  /// await redis.sendCommand(['SET', 'foo', 'bar']);
  /// await redis.sendCommand(['GET', 'foo']);
  /// ```
  Future<dynamic> sendCommand(List<String> commandList) async {
    isBusy = true;
    final value = await _sendCommand(commandList);
    isBusy = false;
    return value;
  }

  /// Get subscribe listener callback related to the channel or pattern
  RedisSubscriber? _findSubscribeListener(String channel) {
    final cb = subscribeListeners.firstWhereOrNull((e) => e.channel == channel);
    return cb;
  }

  /// Login to redis
  Future<dynamic> _login() async {
    final username = option.username;
    final password = option.password;
    if (password != null) {
      final commands = username != null
          ? <String>['AUTH', username, password]
          : <String>['AUTH', password];
      return _sendCommand(commands);
    }
  }

  /// Select database index
  Future<dynamic> _selectDatabaseIndex() async {
    return _sendCommand(<String>['SELECT', option.db.toString()]);
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
}
