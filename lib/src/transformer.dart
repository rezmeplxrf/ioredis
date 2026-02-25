import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:ioredis/src/redis_response.dart';

class BufferedRedisResponseTransformer
    extends StreamTransformerBase<Uint8List, dynamic> {
  static const int _initialCapacity = 4096;

  @override
  Stream<dynamic> bind(Stream<Uint8List> stream) {
    var buffer = Uint8List(_initialCapacity);
    var start = 0;
    var end = 0;

    void ensureCapacity(int additional) {
      final required = end + additional;
      if (required <= buffer.length) {
        return;
      }
      final active = end - start;
      final requiredFromActive = active + additional;
      var newCapacity = max(buffer.length * 2, _initialCapacity);
      while (newCapacity < requiredFromActive) {
        newCapacity *= 2;
      }

      final next = Uint8List(newCapacity);
      if (active > 0) {
        next.setRange(0, active, buffer, start);
      }
      buffer = next;
      start = 0;
      end = active;
    }

    void compactIfNeeded() {
      if (start == 0) {
        return;
      }
      if (start == end) {
        start = 0;
        end = 0;
        return;
      }

      // Compact only when consumed portion is large to avoid frequent copies.
      if (start < buffer.length ~/ 2 && start < 2048) {
        return;
      }
      final active = end - start;
      buffer.setRange(0, active, buffer, start);
      start = 0;
      end = active;
    }

    return stream.transform(
      StreamTransformer<Uint8List, dynamic>.fromHandlers(
        handleData: (data, sink) {
          ensureCapacity(data.length);
          buffer.setRange(end, end + data.length, data);
          end += data.length;

          while (end > start) {
            final parsed = RedisResponse.tryParseBytesWithConsumedInRange(
              buffer,
              start,
              end,
            );
            if (parsed == null) break;
            sink.add(parsed.$1);
            start += parsed.$2;
            compactIfNeeded();
          }
        },
        handleError: (err, st, sink) {
          sink.addError(err);
        },
        handleDone: (sink) {
          start = 0;
          end = 0;
          sink.close();
        },
      ),
    );
  }
}

class BufferedRedisStringResponseTransformer
    extends StreamTransformerBase<String, dynamic> {
  @override
  Stream<dynamic> bind(Stream<String> stream) {
    var buffer = '';
    return stream.transform(
      StreamTransformer<String, dynamic>.fromHandlers(
        handleData: (data, sink) {
          buffer += data;
          while (buffer.isNotEmpty) {
            final parsed = RedisResponse.tryParseWithConsumed(buffer);
            if (parsed == null) break;
            sink.add(parsed.$1);
            buffer = buffer.substring(parsed.$2);
          }
        },
        handleError: (err, st, sink) {
          sink.addError(err);
        },
        handleDone: (sink) {
          buffer = '';
          sink.close();
        },
      ),
    );
  }
}

StreamTransformer<String, dynamic> redisResponseTransformer =
    BufferedRedisStringResponseTransformer();
