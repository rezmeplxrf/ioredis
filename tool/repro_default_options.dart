import 'package:ioredis/ioredis.dart';

void main() {
  final a = Redis();
  final b = Redis();
  a.option.keyPrefix = 'changed';
  print('a=${a.option.keyPrefix}, b=${b.option.keyPrefix}');
}
