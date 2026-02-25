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
}

class RedisSetOption {}
