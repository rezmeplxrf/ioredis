import 'dart:math';

import 'package:ioredis/src/redis_error.dart';

typedef RedisRetryPredicate = bool Function(
  RedisError error,
  int attempt,
  List<String> command,
);

typedef RedisRetryStopCondition = bool Function(RedisError error);

enum RedisRetryJitter {
  none,
  full,
  equal,
}

class RedisRetryPolicy {
  const RedisRetryPolicy({
    this.maxAttempts = 1,
    this.initialDelay = const Duration(milliseconds: 50),
    this.maxDelay = const Duration(seconds: 2),
    this.backoffFactor = 2.0,
    this.jitter = RedisRetryJitter.none,
    this.shouldRetry,
    this.stopCondition,
  })  : assert(maxAttempts >= 1, 'maxAttempts must be >= 1'),
        assert(backoffFactor >= 1.0, 'backoffFactor must be >= 1.0');

  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final double backoffFactor;
  final RedisRetryJitter jitter;
  final RedisRetryPredicate? shouldRetry;
  final RedisRetryStopCondition? stopCondition;

  bool canRetry(RedisError error, int attempt, List<String> command) {
    if (attempt >= maxAttempts) {
      return false;
    }
    if (stopCondition?.call(error) ?? false) {
      return false;
    }
    final predicate = shouldRetry;
    if (predicate != null) {
      return predicate(error, attempt, command);
    }
    return error is RedisTimeoutError ||
        error is RedisConnectionError ||
        error is RedisAskError ||
        error is RedisMovedError;
  }

  Duration nextDelay(int attempt, [Random? random]) {
    final rng = random ?? Random();
    final multiplier = pow(backoffFactor, attempt - 1).toDouble();
    final rawMs = initialDelay.inMilliseconds * multiplier;
    final cappedMs = min(rawMs, maxDelay.inMilliseconds.toDouble());
    final baseMs = cappedMs.round();
    switch (jitter) {
      case RedisRetryJitter.none:
        return Duration(milliseconds: baseMs);
      case RedisRetryJitter.full:
        return Duration(milliseconds: rng.nextInt(baseMs + 1));
      case RedisRetryJitter.equal:
        final half = (baseMs / 2).round();
        return Duration(milliseconds: half + rng.nextInt(half + 1));
    }
  }
}
