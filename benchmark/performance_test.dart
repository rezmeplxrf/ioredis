import 'package:ioredis/src/redis_message_encoder.dart';
import 'package:ioredis/src/redis_response.dart';

void main() {
  // Performance benchmark for the optimized Redis response parsing
  benchmarkResponseParsing();
  benchmarkMessageEncoding();
}

void benchmarkResponseParsing() {
  print('=== Redis Response Parsing Benchmark ===');

  // Test data
  const simpleString = '+OK\r\n';
  const bulkString = '\$5\r\nhello\r\n';
  const integerResponse = ':42\r\n';
  const arrayResponse = '*3\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n\$3\r\nbaz\r\n';
  const errorResponse = '-Error message\r\n';

  const iterations = 100000;

  // Benchmark simple string parsing
  final sw1 = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    RedisResponse.transform(simpleString);
  }
  sw1.stop();
  print(
      'Simple string parsing: ${sw1.elapsedMicroseconds}μs for $iterations iterations');
  print('Average: ${sw1.elapsedMicroseconds / iterations}μs per operation');

  // Benchmark bulk string parsing
  final sw2 = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    RedisResponse.transform(bulkString);
  }
  sw2.stop();
  print(
      'Bulk string parsing: ${sw2.elapsedMicroseconds}μs for $iterations iterations');
  print('Average: ${sw2.elapsedMicroseconds / iterations}μs per operation');

  // Benchmark integer parsing
  final sw3 = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    RedisResponse.transform(integerResponse);
  }
  sw3.stop();
  print(
      'Integer parsing: ${sw3.elapsedMicroseconds}μs for $iterations iterations');
  print('Average: ${sw3.elapsedMicroseconds / iterations}μs per operation');

  // Benchmark array parsing
  final sw4 = Stopwatch()..start();
  for (var i = 0; i < 10000; i++) {
    // Fewer iterations for arrays as they're more complex
    RedisResponse.transform(arrayResponse);
  }
  sw4.stop();
  print('Array parsing: ${sw4.elapsedMicroseconds}μs for 10000 iterations');
  print('Average: ${sw4.elapsedMicroseconds / 10000}μs per operation');

  // Benchmark error parsing
  final sw5 = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    RedisResponse.transform(errorResponse);
  }
  sw5.stop();
  print(
      'Error parsing: ${sw5.elapsedMicroseconds}μs for $iterations iterations');
  print('Average: ${sw5.elapsedMicroseconds / iterations}μs per operation');

  print('');
}

void benchmarkMessageEncoding() {
  print('=== Redis Message Encoding Benchmark ===');

  final encoder = RedisMessageEncoder();
  const iterations = 100000;

  // Test simple string encoding
  final sw1 = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    encoder.encode('hello');
  }
  sw1.stop();
  print(
      'String encoding: ${sw1.elapsedMicroseconds}μs for $iterations iterations');
  print('Average: ${sw1.elapsedMicroseconds / iterations}μs per operation');

  // Test array encoding
  final testArray = ['GET', 'key'];
  final sw2 = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    encoder.encode(testArray);
  }
  sw2.stop();
  print(
      'Array encoding: ${sw2.elapsedMicroseconds}μs for $iterations iterations');
  print('Average: ${sw2.elapsedMicroseconds / iterations}μs per operation');

  // Test integer encoding
  final sw3 = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    encoder.encode(42);
  }
  sw3.stop();
  print(
      'Integer encoding: ${sw3.elapsedMicroseconds}μs for $iterations iterations');
  print('Average: ${sw3.elapsedMicroseconds / iterations}μs per operation');

  // Test large array encoding
  final largeArray = List.generate(100, (i) => 'item$i');
  final sw4 = Stopwatch()..start();
  for (var i = 0; i < 1000; i++) {
    // Fewer iterations for large arrays
    encoder.encode(largeArray);
  }
  sw4.stop();
  print(
      'Large array encoding: ${sw4.elapsedMicroseconds}μs for 1000 iterations');
  print('Average: ${sw4.elapsedMicroseconds / 1000}μs per operation');

  print('');
}
