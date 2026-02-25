typedef RedisSubscriberCallback = void Function(
    String channel, String? message);

typedef RedisUnsubscribeHandler = Future<void> Function();

class RedisSubscriber {
  RedisSubscriber({
    required this.channel,
    required this.isPattern,
    this.isSharded = false,
    this.onMessage,
    RedisUnsubscribeHandler? onUnsubscribe,
  }) : _onUnsubscribe = onUnsubscribe;
  final String channel;
  final bool isPattern;
  final bool isSharded;
  RedisSubscriberCallback? onMessage;
  final RedisUnsubscribeHandler? _onUnsubscribe;

  Future<void> unsubscribe() async {
    final unsub = _onUnsubscribe;
    if (unsub == null) return;
    await unsub();
  }

  @override
  String toString() =>
      'RedisSubscriber(channel: $channel, isPattern: $isPattern, isSharded: $isSharded, onMessage: $onMessage)';
}
