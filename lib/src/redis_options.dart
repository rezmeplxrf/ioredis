import 'package:ioredis/src/redis_event.dart';
import 'package:ioredis/src/redis_retry_policy.dart';

class RedisSentinelNode {
  const RedisSentinelNode({
    required this.host,
    required this.port,
  });

  final String host;
  final int port;
}

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
    this.enableClusterMode = false,
    this.maxClusterRedirects = 5,
    this.enableSentinelMode = false,
    this.sentinelMasterName,
    this.sentinels = const <RedisSentinelNode>[],
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

  /// enable MOVED/ASK auto redirect handling.
  bool enableClusterMode;

  /// maximum redirects for a single command in cluster mode.
  int maxClusterRedirects;

  /// enable Sentinel master discovery and failover handling.
  bool enableSentinelMode;

  /// monitored master name in Sentinel.
  String? sentinelMasterName;

  /// sentinel endpoints for master discovery.
  List<RedisSentinelNode> sentinels;

  /// max commands written in one pipeline batch.
  int pipelineBatchSize;

  /// hard cap for pending responses to bound memory usage.
  int maxPendingCommands;
}

class RedisSetOption {}
