import 'dart:io';

import 'package:ioredis/src/redis_event.dart';
import 'package:ioredis/src/redis_response.dart';
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
    this.protocolVersion = 3,
    this.preserveResp3Attributes = false,
    this.onEvent,
    this.onPush,
    this.pipelineBatchSize = 256,
    this.maxPendingCommands = 10000,
    this.tlsContext,
    this.onBadCertificate,
    this.supportedProtocols,
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

  /// Callback for RESP3 push messages, including invalidation pushes.
  void Function(RedisPushData push)? onPush;

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
  /// 2 = RESP2, 3 = RESP3 via HELLO (default).
  /// When set to 3, connection falls back to RESP2 if HELLO is unsupported.
  int protocolVersion;

  /// When true, keep RESP3 attribute wrappers in command replies.
  /// When false (default), only wrapped data is returned.
  bool preserveResp3Attributes;

  /// max commands written in one pipeline batch.
  int pipelineBatchSize;

  /// hard cap for pending responses to bound memory usage.
  int maxPendingCommands;

  /// TLS context used when [secure] is true.
  SecurityContext? tlsContext;

  /// Optional certificate verifier for TLS connections.
  bool Function(X509Certificate certificate)? onBadCertificate;

  /// Optional ALPN protocol list for TLS connections.
  List<String>? supportedProtocols;

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
      preserveResp3Attributes: preserveResp3Attributes,
      onEvent: onEvent,
      onPush: onPush,
      pipelineBatchSize: pipelineBatchSize,
      maxPendingCommands: maxPendingCommands,
      tlsContext: tlsContext,
      onBadCertificate: onBadCertificate,
      supportedProtocols: supportedProtocols == null
          ? null
          : List<String>.from(supportedProtocols!),
    );
  }
}

class RedisSetOption {}
