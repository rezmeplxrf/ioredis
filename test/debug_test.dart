// ignore_for_file: use_raw_strings

import 'dart:convert';
import 'package:ioredis/ioredis.dart';
import 'package:test/test.dart';

void main() async {
  final redis = Redis(RedisOptions(host: '127.0.0.1', port: 6379));

  setUpAll(() async {
    await redis.connect();
  });

  tearDownAll(() async {
    await redis.disconnect();
  });

  test('simple special characters test', () async {
    const key = 'test:json:simple-special';
    const path = '.';

    final simpleValue = {
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
    await redis.jsonSet(key, path, simpleValue);

    // Get JSON value
    final result = await redis.jsonGet(key, path);
    expect(result, isNotNull);

    final decodedResult = jsonDecode(result!);
    expect(decodedResult['text'],
        equals('This is a test with\nnewlines and\r\ncarriage returns'));
    expect(decodedResult['json'], equals('{"nested": "value with\nnewlines"}'));
    expect(decodedResult['array'][0], equals('item1\nwith\nnewlines'));
    expect(decodedResult['unicode'], equals('Unicode: 🎉 🚀 ñáéíóú'));
    expect(decodedResult['quotes'],
        equals('Text with "quotes" and \'single quotes\''));
    expect(decodedResult['backslashes'],
        equals('Path\\to\\file\\with\\backslashes'));
    expect(decodedResult['mixed'],
        equals('Mixed\nspecial\r\ncharacters\twith\ttabs and "quotes"'));
  });
}
