import 'dart:math';

import 'package:ioredis/ioredis.dart';

RedisOptions defaultRedisOptions() {
  return RedisOptions(
    retryStrategy: (times) {
      return Duration(milliseconds: min(times * 50, 2000));
    },
  );
}
