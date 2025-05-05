enum RedisConnectionStatus {
  connected('connected'),
  disconnected('disconnected'),
  connecting('connecting');

  const RedisConnectionStatus(this.name);
  final String name;
}
