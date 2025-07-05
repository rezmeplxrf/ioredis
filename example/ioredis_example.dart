import 'package:ioredis/ioredis.dart';

void main() async {
  // ignore: avoid_redundant_argument_values
  final redis = Redis(RedisOptions(host: '127.0.0.1', port: 6379));

  /// Set value
  await redis.set('key', 'value');

  /// Get value
  final result = await redis.get('key');
  print(result);
}
