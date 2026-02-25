import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ioredis/src/redis_response.dart';

StreamTransformer<Uint8List, String> transformer =
    StreamTransformer<Uint8List, String>.fromBind((stream) {
  return utf8.decoder.bind(stream);
});

class BufferedRedisResponseTransformer
    extends StreamTransformerBase<String, dynamic> {
  @override
  Stream<dynamic> bind(Stream<String> stream) {
    var buffer = '';
    return stream.transform(
      StreamTransformer<String, dynamic>.fromHandlers(
        handleData: (data, sink) {
          buffer += data;

          // Try to parse complete responses from the buffer
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
    BufferedRedisResponseTransformer();
