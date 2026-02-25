class RedisError implements Exception {
  RedisError(
    this.message, {
    this.command,
    this.cause,
  });

  final String message;
  final List<String>? command;
  final Object? cause;

  @override
  String toString() => 'RedisError: $message';
}

class RedisConnectionError extends RedisError {
  RedisConnectionError(
    super.message, {
    super.command,
    super.cause,
  });

  @override
  String toString() => 'RedisConnectionError: $message';
}

class RedisTimeoutError extends RedisError {
  RedisTimeoutError({
    required this.timeout,
    List<String>? command,
  }) : super(
          'Command timed out after ${timeout.inMilliseconds}ms',
          command: command,
        );

  final Duration timeout;

  @override
  String toString() =>
      'RedisTimeoutError(${timeout.inMilliseconds}ms): $message';
}

class RedisProtocolError extends RedisError {
  RedisProtocolError(
    super.message, {
    super.command,
    super.cause,
  });

  @override
  String toString() => 'RedisProtocolError: $message';
}

class RedisCommandError extends RedisError {
  RedisCommandError(
    this.code,
    super.message, {
    super.command,
    super.cause,
  });

  final String code;

  @override
  String toString() => 'RedisCommandError($code): $message';
}

class RedisAuthError extends RedisCommandError {
  RedisAuthError(
    String message, {
    List<String>? command,
  }) : super('AUTH', message, command: command);

  @override
  String toString() => 'RedisAuthError: $message';
}

class RedisErrorMapper {
  static RedisError map(dynamic error, {List<String>? command}) {
    if (error is RedisError) {
      return error;
    }
    if (error is RedisServerErrorReply) {
      return fromServerError(error.message, command: command);
    }
    final message = error?.toString() ?? 'Unknown redis error';
    return RedisConnectionError(message, command: command, cause: error);
  }

  static RedisError fromServerError(String message, {List<String>? command}) {
    final upper = message.toUpperCase();
    if (upper.startsWith('WRONGPASS') ||
        upper.startsWith('NOAUTH') ||
        upper.startsWith('AUTH')) {
      return RedisAuthError(message, command: command);
    }
    final code = _extractCode(message);
    return RedisCommandError(code, message, command: command);
  }

  static String _extractCode(String message) {
    final index = message.indexOf(' ');
    if (index == -1) {
      return message.toUpperCase();
    }
    return message.substring(0, index).toUpperCase();
  }
}

class RedisServerErrorReply {
  RedisServerErrorReply(this.message);

  final String message;

  @override
  String toString() => message;
}
