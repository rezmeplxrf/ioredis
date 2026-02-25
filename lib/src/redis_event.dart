class RedisEvent {
  const RedisEvent({
    required this.type,
    this.command,
    this.endpoint,
    this.attempt,
    this.duration,
    this.error,
  });

  final RedisEventType type;
  final List<String>? command;
  final String? endpoint;
  final int? attempt;
  final Duration? duration;
  final Object? error;
}

enum RedisEventType {
  connectStart,
  connectSuccess,
  reconnectAttempt,
  disconnect,
  commandSuccess,
  commandRetry,
  commandError,
}
