import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ioredis/src/redis_response.dart';

StreamTransformer<Uint8List, String> transformer =
    StreamTransformer<Uint8List, String>.fromHandlers(
  handleData: (data, sink) {
    sink.add(utf8.decode(data));
  },
  handleError: (err, st, sink) {
    sink.addError(err);
  },
  handleDone: (sink) {
    sink.close();
  },
);

class BufferedRedisResponseTransformer
    extends StreamTransformerBase<String, dynamic> {
  String _buffer = '';
  static const String _crlf = '\r\n';

  @override
  Stream<dynamic> bind(Stream<String> stream) {
    return stream.transform(
      StreamTransformer<String, dynamic>.fromHandlers(
        handleData: (data, sink) {
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
        handleError: (err, st, sink) {
          sink.addError(err);
        },
        handleDone: (sink) {
          _buffer = '';
          sink.close();
        },
      ),
    );
  }

  (dynamic, String)? _tryParseCompleteResponse() {
    if (_buffer.isEmpty) return null;

    final firstChar = _buffer.codeUnitAt(0);

    switch (firstChar) {
      case 43: // '+' Simple string
      case 45: // '-' Error
      case 58: // ':' Integer
        return _parseSimpleResponse();

      case 36: // '$' Bulk string
        return _parseBulkString();

      case 42: // '*' Array
        return _parseArray();

      default:
        // Try to parse as-is and see if it works
        final result = RedisResponse.transform(_buffer);
        if (result != null) {
          return (result, '');
        }
        return null;
    }
  }

  (dynamic, String)? _parseSimpleResponse() {
    final crlfIndex = _buffer.indexOf(_crlf);
    if (crlfIndex == -1) return null; // Need more data

    final responseStr = _buffer.substring(0, crlfIndex + 2);
    final remaining = _buffer.substring(crlfIndex + 2);
    final result = RedisResponse.transform(responseStr);
    return (result, remaining);
  }

  (dynamic, String)? _parseBulkString() {
    final firstCrlfIndex = _buffer.indexOf(_crlf);
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

    // Convert to bytes to properly handle UTF-8 length
    final bufferBytes = utf8.encode(_buffer);
    final headerBytes = utf8.encode(_buffer.substring(0, dataStartIndex));
    final requiredBytes = headerBytes.length + length + 2; // +2 for final \r\n

    if (bufferBytes.length < requiredBytes) {
      return null; // Need more data
    }

    // Convert back to string by finding the correct character boundary
    String responseStr;
    try {
      final responseBytes = bufferBytes.sublist(0, requiredBytes);
      responseStr = utf8.decode(responseBytes);
    } catch (e) {
      return null; // Invalid UTF-8 sequence
    }

    final remaining = utf8.decode(bufferBytes.sublist(requiredBytes));
    final result = RedisResponse.transform(responseStr);
    return (result, remaining);
  }

  (dynamic, String)? _parseArray() {
    final parsed = RedisResponse.tryParseWithConsumed(_buffer);
    if (parsed == null) return null;

    final (result, consumedChars) = parsed;
    if (consumedChars <= 0 || consumedChars > _buffer.length) return null;

    final remaining = _buffer.substring(consumedChars);
    return (result, remaining);
  }
}

StreamTransformer<String, dynamic> redisResponseTransformer =
    BufferedRedisResponseTransformer();
