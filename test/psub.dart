import 'package:ioredis/ioredis.dart';

void main() async {
  final client = Redis(RedisOptions(
    username: 'default',
    idleTimeout: const Duration(seconds: 30),
  ));
  await client.connection.connect();

  final stream = await client.psubscribe('*');
  stream.onMessage = (String channel, String? message) {
    print('$channel - $message');
  };
}
