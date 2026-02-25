import 'dart:convert';
import 'dart:typed_data';

class RedisMessageEncoder {
  RedisMessageEncoder() {
    if (_lengthCache.isEmpty) {
      _initCache();
    }
  }
  // Pre-allocated constants to avoid repeated allocations
  static const List<int> _semicolon = [58]; // ':'
  static const List<int> _crlf = [13, 10]; // '\r\n'
  static const List<int> _star = [42]; // '*'
  static const List<int> _nullValue = [36, 45, 49, 13, 10]; // '$-1\r\n'
  static const List<int> _dollar = [36]; // '$'

  // Cache for frequently used length strings
  static final Map<int, List<int>> _lengthCache = <int, List<int>>{};

  // Pre-populate cache for common lengths
  static void _initCache() {
    for (var i = 0; i <= 100; i++) {
      _lengthCache[i] = ascii.encode(i.toString());
    }
  }

  List<int> encode(Object? object) {
    final buffer = BytesBuilder(copy: false);
    _consume(object, buffer);
    return buffer.toBytes();
  }

  void _consume(Object? object, BytesBuilder buffer) {
    switch (object) {
      case String():
        _encodeString(object, buffer);
      case Uint8List():
        _encodeBinary(object, buffer);
      case Iterable():
        _encodeArray(object, buffer);
      case int():
        _encodeInteger(object, buffer);
      default:
        if (object == null) {
          buffer.add(_nullValue);
        } else {
          throw Exception('unable to serialize type: ${object.runtimeType}');
        }
    }
  }

  void _encodeString(String value, BytesBuilder buffer) {
    final data = utf8.encode(value);
    buffer.add(_dollar);

    // Use cached length if available
    final lengthBytes =
        _lengthCache[data.length] ?? ascii.encode(data.length.toString());
    buffer.add(lengthBytes);

    buffer.add(_crlf);
    buffer.add(data);
    buffer.add(_crlf);
  }

  void _encodeArray(Iterable<dynamic> array, BytesBuilder buffer) {
    final length = array.length;
    buffer.add(_star);

    // Use cached length if available
    final lengthBytes = _lengthCache[length] ?? ascii.encode(length.toString());
    buffer.add(lengthBytes);

    buffer.add(_crlf);
    for (final dynamic item in array) {
      _consume(item is int ? item.toString() : item, buffer);
    }
  }

  void _encodeBinary(Uint8List data, BytesBuilder buffer) {
    buffer.add(_dollar);
    final lengthBytes =
        _lengthCache[data.length] ?? ascii.encode(data.length.toString());
    buffer.add(lengthBytes);
    buffer.add(_crlf);
    buffer.add(data);
    buffer.add(_crlf);
  }

  void _encodeInteger(int value, BytesBuilder buffer) {
    buffer.add(_semicolon);

    // Use cached value if available for small numbers
    final valueBytes = _lengthCache[value] ?? ascii.encode(value.toString());
    buffer.add(valueBytes);

    buffer.add(_crlf);
  }

  // Legacy method for backward compatibility
  void consume(Object? object, void Function(Iterable<int> s) add) {
    final buffer = BytesBuilder(copy: false);
    _consume(object, buffer);
    add(buffer.toBytes());
  }
}
