import 'package:ioredis/src/redis_event.dart';
import 'package:ioredis/src/redis_retry_policy.dart';

class RedisOptions {
  RedisOptions({
    this.keyPrefix = '',
    this.host = '127.0.0.1',
    this.port = 6379,
    this.secure = false,
    this.connectTimeout = const Duration(seconds: 10),
    this.commandTimeout,
    this.username,
    this.password,
    this.db = 0,
    this.retryStrategy,
    this.retryPolicy,
    this.onError,
    this.maxConnection = 10,
    this.idleTimeout = const Duration(seconds: 10),
    this.protocolVersion = 2,
    this.onEvent,
    this.pipelineBatchSize = 256,
    this.maxPendingCommands = 10000,
  });

  /// timeout value for socket connection
  final Duration connectTimeout;

  /// default timeout value for each command request.
  final Duration? commandTimeout;

  /// use secure socket
  final bool secure;

  /// retry strategy defaults to
  /// `min(50 * times, 2000)`
  final Duration Function(int)? retryStrategy;

  /// command retry policy for transient command failures.
  final RedisRetryPolicy? retryPolicy;

  /// redis username
  final String? username;

  /// redis password
  final String? password;

  /// redis host
  String host;

  /// redis port
  int port;

  /// database index defaults to 0
  int db;

  /// error handler
  void Function(dynamic)? onError;

  /// structured event callback for observability.
  void Function(RedisEvent event)? onEvent;

  /// key prefix
  /// ```
  /// Redis fooRedis = new Redis(RedisOption(keyPrefix: 'foo'));
  /// fooRedis.set("bar", "baz"); // Actually sends SET foo:bar baz
  /// ```
  String keyPrefix;

  /// maximum connection pool, default to 10;
  int maxConnection;

  /// timeout duration of idle connection in the pool, default to 10s
  Duration idleTimeout;

  /// RESP protocol version.
  /// 2 = RESP2 (default), 3 = RESP3 via HELLO.
  int protocolVersion;

  /// max commands written in one pipeline batch.
  int pipelineBatchSize;

  /// hard cap for pending responses to bound memory usage.
  int maxPendingCommands;

  RedisOptions clone() {
    return RedisOptions(
      keyPrefix: keyPrefix,
      host: host,
      port: port,
      secure: secure,
      connectTimeout: connectTimeout,
      commandTimeout: commandTimeout,
      username: username,
      password: password,
      db: db,
      retryStrategy: retryStrategy,
      retryPolicy: retryPolicy,
      onError: onError,
      maxConnection: maxConnection,
      idleTimeout: idleTimeout,
      protocolVersion: protocolVersion,
      onEvent: onEvent,
      pipelineBatchSize: pipelineBatchSize,
      maxPendingCommands: maxPendingCommands,
    );
  }
}

class RedisSetOption {}
