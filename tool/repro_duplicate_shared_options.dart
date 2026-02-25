import 'package:ioredis/ioredis.dart';

void main() {
  final a = Redis(RedisOptions(keyPrefix: 'a'));
  final b = a.duplicate();
  b.option.keyPrefix = 'b';
  print('a=${a.option.keyPrefix}, b=${b.option.keyPrefix}');
}
