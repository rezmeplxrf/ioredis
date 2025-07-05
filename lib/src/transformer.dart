import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ioredis/src/redis_response.dart';

StreamTransformer<Uint8List, String> transformer =
    StreamTransformer<Uint8List, String>.fromHandlers(
  handleData: (List<int> data, EventSink<String> sink) {
    sink.add(utf8.decode(data));
  },
  handleError: (Object err, StackTrace st, EventSink<String> sink) {
    sink.addError(err);
  },
  handleDone: (EventSink<String> sink) {
    sink.close();
  },
);

class BufferedRedisResponseTransformer
    extends StreamTransformerBase<String, dynamic> {
  String _buffer = '';

  @override
  Stream<dynamic> bind(Stream<String> stream) {
    return stream.transform(
      StreamTransformer<String, dynamic>.fromHandlers(
        handleData: (String data, EventSink<dynamic> sink) {
          _buffer += data;

          // Try to parse complete responses from the buffer
          while (_buffer.isNotEmpty) {
            final result = _tryParseCompleteResponse();
            if (result != null) {
              final (parsedResult, remainingBuffer) = result;
              _buffer = remainingBuffer;
              sink.add(parsedResult);
            } else {
              break; // Need more data
            }
          }
        },
        handleError: (Object err, StackTrace st, EventSink<dynamic> sink) {
          sink.addError(err);
        },
        handleDone: (EventSink<dynamic> sink) {
          _buffer = '';
          sink.close();
        },
      ),
    );
  }

  (dynamic, String)? _tryParseCompleteResponse() {
    if (_buffer.isEmpty) return null;

    final firstChar = _buffer[0];

    switch (firstChar) {
      case '+': // Simple string
      case '-': // Error
      case ':': // Integer
        final crlfIndex = _buffer.indexOf('\r\n');
        if (crlfIndex == -1) return null; // Need more data

        final responseStr = _buffer.substring(0, crlfIndex + 2);
        final remaining = _buffer.substring(crlfIndex + 2);
        final result = RedisResponse.transform(responseStr);
        return (result, remaining);

      case '\$': // Bulk string
        final firstCrlfIndex = _buffer.indexOf('\r\n');
        if (firstCrlfIndex == -1) return null; // Need more data

        final lengthStr = _buffer.substring(1, firstCrlfIndex);
        final length = int.tryParse(lengthStr);
        if (length == null) return null;

        if (length == -1) {
          // Null bulk string
          final responseStr = _buffer.substring(0, firstCrlfIndex + 2);
          final remaining = _buffer.substring(firstCrlfIndex + 2);
          final result = RedisResponse.transform(responseStr);
          return (result, remaining);
        }

        // Check if we have the complete bulk string
        final dataStartIndex = firstCrlfIndex + 2;
        final dataEndIndex = dataStartIndex + length;
        final messageEndIndex = dataEndIndex + 2; // +2 for final \r\n

        if (_buffer.length < messageEndIndex) {
          return null; // Need more data
        }

        final responseStr = _buffer.substring(0, messageEndIndex);
        final remaining = _buffer.substring(messageEndIndex);
        final result = RedisResponse.transform(responseStr);
        return (result, remaining);

      case '*': // Array
        // For arrays, we need to parse them completely
        // This is more complex, so let's use the original parsing for now
        // and fall back to waiting for more data if needed
        final result = RedisResponse.transform(_buffer);
        if (result != null) {
          return (result, '');
        }
        return null;

      default:
        // Try to parse as-is and see if it works
        final result = RedisResponse.transform(_buffer);
        if (result != null) {
          return (result, '');
        }
        return null;
    }
  }
}

StreamTransformer<String, dynamic> redisResponseTransformer =
    BufferedRedisResponseTransformer();
