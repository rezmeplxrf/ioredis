import 'dart:convert';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() async {
  final redis = Redis(RedisOptions(
      username: 'default',
      password: '6XCSP07Y26/iX3kd6ynMRZ7s9vo8IwMY4A6U9gvLdOw='));

  setUpAll(() async {
    await redis.connect();
  });

  tearDownAll(() async {
    await redis.disconnect();
  });

  group('Redis JSON commands', () {
    test('jsonSet and jsonGet with Dart object', () async {
      const key = 'test:json:object';
      const path = '.';
      final value = {'name': 'John', 'age': 30};

      // Set JSON value
      await redis.jsonSet(key, path, value);

      // Get JSON value
      final result = await redis.jsonGet(key, path);
      final decodedResult = jsonDecode(result!);

      expect(decodedResult, equals(value));
    });

    test('jsonSet and jsonGet with JSON string', () async {
      const key = 'test:json:string';
      const path = '.';
      const value = '{"name":"Jane","age":25}';

      // Set JSON value
      await redis.jsonSet(key, path, value);

      // Get JSON value
      final result = await redis.jsonGet(key, path);
      final decodedResult = jsonDecode(result!);
      print(decodedResult);
      expect(decodedResult, equals(jsonDecode(value)));
    });

    test('jsonQuery with JSON path', () async {
      const key = 'test:json:query';
      const path = '.';
      final value = {'name': 'Doe', 'age': 40};

      // Set JSON value
      await redis.jsonSet(key, path, value);

      // Query JSON value
      const queryPath = r'$.name';
      final result = await redis.jsonGet(key, queryPath);
      final decodedResult = jsonDecode(result!);
      print(decodedResult);

      // The result is an array
      expect(decodedResult[0], equals('Doe'));
    });
  });
}
