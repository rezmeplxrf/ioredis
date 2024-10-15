typedef RedisSubscriberCallback = void Function(
    String channel, String? message);

class RedisSubscriber {
  RedisSubscriber({required this.channel, this.onMessage});
  final String channel;
  RedisSubscriberCallback? onMessage;

  @override
  String toString() =>
      'RedisSubscriber(channel: $channel, onMessage: $onMessage)';
}
