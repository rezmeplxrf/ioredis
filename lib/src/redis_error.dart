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

class RedisMovedError extends RedisCommandError {
  RedisMovedError({
    required this.slot,
    required this.host,
    required this.port,
    required String message,
    List<String>? command,
  }) : super(
          'MOVED',
          message,
          command: command,
        );

  final int slot;
  final String host;
  final int port;
}

class RedisAskError extends RedisCommandError {
  RedisAskError({
    required this.slot,
    required this.host,
    required this.port,
    required String message,
    List<String>? command,
  }) : super(
          'ASK',
          message,
          command: command,
        );

  final int slot;
  final String host;
  final int port;
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
    if (upper.startsWith('MOVED ')) {
      final moved = _parseMovedAsk(message, command, moved: true);
      if (moved != null) return moved;
    }
    if (upper.startsWith('ASK ')) {
      final ask = _parseMovedAsk(message, command, moved: false);
      if (ask != null) return ask;
    }
    final code = _extractCode(message);
    return RedisCommandError(code, message, command: command);
  }

  static RedisCommandError? _parseMovedAsk(
    String message,
    List<String>? command, {
    required bool moved,
  }) {
    final parts = message.split(' ');
    if (parts.length < 3) return null;
    final slot = int.tryParse(parts[1]);
    final targetParts = parts[2].split(':');
    if (slot == null || targetParts.length != 2) return null;
    final host = targetParts[0];
    final port = int.tryParse(targetParts[1]);
    if (port == null) return null;
    if (moved) {
      return RedisMovedError(
        slot: slot,
        host: host,
        port: port,
        message: message,
        command: command,
      );
    }
    return RedisAskError(
      slot: slot,
      host: host,
      port: port,
      message: message,
      command: command,
    );
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
