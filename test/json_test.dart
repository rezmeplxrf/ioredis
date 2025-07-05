// ignore_for_file: avoid_redundant_argument_values, use_raw_strings

import 'dart:convert';

import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

// docker run -d --name redis-stack \
//   -p 6379:6379 -p 8001:8001 \
//   --restart unless-stopped \
//   -e REDIS_PASSWORD=pass \
//   redis/redis-stack:latest

void main() async {
  final redis = Redis(RedisOptions(host: '127.0.0.1', port: 6379, password: 'pass'));

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

    test('jsonSet and jsonGet with large JSON data', () async {
      const key = 'test:json:large';
      const path = '.';

      // Create a large JSON object with multiple levels and arrays
      final largeValue = {
        'users': List.generate(
            1000,
            (index) => {
                  'id': index,
                  'name': 'User $index',
                  'email': 'user$index@example.com',
                  'profile': {
                    'firstName': 'First$index',
                    'lastName': 'Last$index',
                    'bio':
                        'This is a very long biography for user $index. ' * 10,
                    'preferences': {
                      'theme': 'dark',
                      'notifications': true,
                      'language': 'en',
                      'timezone': 'UTC',
                      'features': [
                        'feature1',
                        'feature2',
                        'feature3',
                        'feature4'
                      ]
                    },
                    'history': List.generate(
                        50,
                        (historyIndex) => {
                              'action': 'Action $historyIndex',
                              'timestamp':
                                  DateTime.now().millisecondsSinceEpoch -
                                      (historyIndex * 1000),
                              'details':
                                  'Long details for action $historyIndex. ' * 5
                            })
                  }
                }),
        'metadata': {
          'version': '1.0.0',
          'createdAt': DateTime.now().toIso8601String(),
          'description':
              'This is a test dataset with a large amount of JSON data to test the Redis JSON functionality with large payloads. ' *
                  20,
          'tags': List.generate(100, (index) => 'tag$index'),
          'config': {
            'maxUsers': 10000,
            'enableLogging': true,
            'logLevel': 'debug',
            'features': {
              'authentication': true,
              'authorization': true,
              'caching': true,
              'monitoring': true
            }
          }
        }
      };

      // Set large JSON value
      await redis.jsonSet(key, path, largeValue);

      // Get large JSON value
      final result = await redis.jsonGet(key, path);
      expect(result, isNotNull);

      // Verify the result is valid JSON
      final decodedResult = jsonDecode(result!);
      expect(decodedResult, isA<Map<String, dynamic>>());

      // Verify some key data
      expect(decodedResult['users'], isA<List<dynamic>>());
      expect(decodedResult['users'].length, equals(1000));
      expect(decodedResult['users'][0]['name'], equals('User 0'));
      expect(decodedResult['users'][999]['name'], equals('User 999'));
      expect(decodedResult['metadata']['version'], equals('1.0.0'));
      expect(decodedResult['metadata']['tags'].length, equals(100));

      // Verify nested data integrity
      expect(
          decodedResult['users'][0]['profile']['history'].length, equals(50));
      expect(
          decodedResult['users'][0]['profile']['preferences']['features']
              .length,
          equals(4));
    });

    test(
        'jsonSet and jsonGet with JSON containing newlines and special characters',
        () async {
      const key = 'test:json:special';
      const path = '.';

      final specialValue = {
        'text': 'This is a test with\nnewlines and\r\ncarriage returns',
        'json': '{"nested": "value with\nnewlines"}',
        'array': [
          'item1\nwith\nnewlines',
          'item2\r\nwith\r\ncarriage\r\nreturns'
        ],
        'unicode': 'Unicode: 🎉 🚀 ñáéíóú',
        'quotes': 'Text with "quotes" and \'single quotes\'',
        'backslashes': 'Path\\to\\file\\with\\backslashes',
        'mixed': 'Mixed\nspecial\r\ncharacters\twith\ttabs and "quotes"'
      };

      // Set JSON value with special characters
      await redis.jsonSet(key, path, specialValue);

      // Get JSON value
      final result = await redis.jsonGet(key, path);
      expect(result, isNotNull);

      final decodedResult = jsonDecode(result!);
      expect(decodedResult['text'],
          equals('This is a test with\nnewlines and\r\ncarriage returns'));
      expect(
          decodedResult['json'], equals('{"nested": "value with\nnewlines"}'));
      expect(decodedResult['array'][0], equals('item1\nwith\nnewlines'));
      expect(decodedResult['unicode'], equals('Unicode: 🎉 🚀 ñáéíóú'));
      expect(decodedResult['quotes'],
          equals('Text with "quotes" and \'single quotes\''));
      expect(decodedResult['backslashes'],
          equals('Path\\to\\file\\with\\backslashes'));
      expect(decodedResult['mixed'],
          equals('Mixed\nspecial\r\ncharacters\twith\ttabs and "quotes"'));
    });
  });
}
