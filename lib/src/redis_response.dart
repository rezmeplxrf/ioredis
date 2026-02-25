import 'dart:convert';
import 'dart:typed_data';

import 'package:ioredis/src/redis_error.dart';

enum RedisResponseConstant {
  ok('OK'),
  simpleString('+'),
  error('-'),
  bulkString(r'$'),
  integer(':'),
  array('*');

  const RedisResponseConstant(this.name);
  final String name;
}

// Pre-computed character codes for faster comparison
class _CharCodes {
  static const int plus = 43; // '+'
  static const int minus = 45; // '-'
  static const int dollar = 36; // '$'
  static const int colon = 58; // ':'
  static const int asterisk = 42; // '*'
  static const int underscore = 95; // '_'
  static const int comma = 44; // ','
  static const int hash = 35; // '#'
  static const int bang = 33; // '!'
  static const int equal = 61; // '='
  static const int percent = 37; // '%'
  static const int tilde = 126; // '~'
  static const int greaterThan = 62; // '>'
  static const int leftParen = 40; // '('
  static const int pipe = 124; // '|'
  static const int cr = 13; // '\r'
  static const int lf = 10; // '\n'
}

enum RedisType {
  normal('normal'),
  subscriber('subscriber'),
  publisher('publisher');

  const RedisType(this.name);
  final String name;
}

class RedisBulkData {
  RedisBulkData(this.bytes);

  final Uint8List bytes;
}

class RedisPushData {
  RedisPushData(this.items);

  final List<dynamic> items;
}

class RedisAttributedData {
  RedisAttributedData({
    required this.attributes,
    required this.data,
  });

  final Map<dynamic, dynamic> attributes;
  final dynamic data;
}

class RedisResponse {
  // Cache for frequently used strings
  static const String _crlf = '\r\n';
  static const String _okResponse = 'OK';
  static const String _plusOkResponse = '+OK';

  @pragma('vm:prefer-inline')
  static bool ok(String? s) {
    return s == _okResponse || s == _plusOkResponse;
  }

  @pragma('vm:prefer-inline')
  static bool isSimpleString(String s) {
    return s.isNotEmpty && s.codeUnitAt(0) == _CharCodes.plus;
  }

  @pragma('vm:prefer-inline')
  static bool isError(String s) {
    return s.isNotEmpty && s.codeUnitAt(0) == _CharCodes.minus;
  }

  @pragma('vm:prefer-inline')
  static bool isBulkString(String s) {
    return s.isNotEmpty && s.codeUnitAt(0) == _CharCodes.dollar;
  }

  @pragma('vm:prefer-inline')
  static bool isInteger(String s) {
    return s.isNotEmpty && s.codeUnitAt(0) == _CharCodes.colon;
  }

  @pragma('vm:prefer-inline')
  static bool isArray(String s) {
    return s.isNotEmpty && s.codeUnitAt(0) == _CharCodes.asterisk;
  }

  @pragma('vm:prefer-inline')
  static String? toSimpleString(String s) {
    if (s.length <= 1) return null;

    final crlfIndex = s.indexOf(_crlf, 1);
    if (crlfIndex == -1) {
      final val = s.substring(1);
      return val.isEmpty ? null : val;
    }

    final val = s.substring(1, crlfIndex);
    return val.isEmpty ? null : val;
  }

  static String? toBulkString(String s) {
    if (!isBulkString(s)) return null;
    final parsed = tryParseWithConsumed(s);
    if (parsed == null) return null;
    final value = parsed.$1;
    return value is String ? value : null;
  }

  static List<dynamic> toArrayString(String s) {
    final parsed = tryParseWithConsumed(s);
    if (parsed == null || parsed.$1 is! List<dynamic>) return <dynamic>[];
    return parsed.$1 as List<dynamic>;
  }

  @pragma('vm:prefer-inline')
  String? toErrorString(String s) {
    if (s.length <= 3) return null; // Minimum: -a\r\n
    return s.substring(1, s.length - 2);
  }

  static dynamic transform(String? s) {
    if (s == null || s.isEmpty) return null;

    if (s == _okResponse || s == _plusOkResponse) return _okResponse;

    final firstChar = s.codeUnitAt(0);

    switch (firstChar) {
      case _CharCodes.plus:
        return toSimpleString(s);
      case _CharCodes.minus:
        final error = toSimpleString(s);
        if (error == null) {
          return RedisServerErrorReply('ERR empty error');
        }
        return RedisServerErrorReply(error);
      case _CharCodes.colon:
        final number = toSimpleString(s);
        if (number == null) return null;
        return int.tryParse(number);
      case _CharCodes.dollar:
        return toBulkString(s);
      case _CharCodes.asterisk:
        return toArrayString(s);
      case _CharCodes.underscore:
        return null;
      case _CharCodes.comma:
        final value = toSimpleString(s);
        return value == null ? null : double.tryParse(value);
      case _CharCodes.hash:
        final value = toSimpleString(s);
        if (value == null) return null;
        return value.toLowerCase() == 't';
      case _CharCodes.leftParen:
        final value = toSimpleString(s);
        if (value == null) return null;
        return BigInt.tryParse(value);
      default:
        return null;
    }
  }

  /// Parse one RESP value from the beginning of [s].
  /// Returns parsed value and consumed character length when complete.
  /// Returns null when [s] does not yet contain a complete value.
  static (dynamic, int)? tryParseWithConsumed(String s) {
    return _parseWithConsumedAt(s, 0);
  }

  static (dynamic, int)? _parseWithConsumedAt(String s, int start) {
    if (start >= s.length) return null;

    final firstChar = s.codeUnitAt(start);

    switch (firstChar) {
      case _CharCodes.plus:
        final lineEnd = s.indexOf(_crlf, start);
        if (lineEnd == -1) return null;
        final value = s.substring(start + 1, lineEnd);
        return (value.isEmpty ? null : value, lineEnd + 2);

      case _CharCodes.colon:
        final lineEnd = s.indexOf(_crlf, start);
        if (lineEnd == -1) return null;
        final value = int.tryParse(s.substring(start + 1, lineEnd));
        return (value, lineEnd + 2);

      case _CharCodes.minus:
        final errorLineEnd = s.indexOf(_crlf, start);
        if (errorLineEnd == -1) return null;
        final errorValue = s.substring(start + 1, errorLineEnd);
        return (RedisServerErrorReply(errorValue), errorLineEnd + 2);

      case _CharCodes.dollar:
        final headerEnd = s.indexOf(_crlf, start);
        if (headerEnd == -1) return null;

        final len = int.tryParse(s.substring(start + 1, headerEnd));
        if (len == null) return null;
        if (len == -1) {
          return (null, headerEnd + 2);
        }

        final dataStart = headerEnd + 2;
        final dataEnd = _advanceByUtf8Bytes(s, dataStart, len);
        if (dataEnd == null) return null;
        if (dataEnd + 2 > s.length) return null;
        if (s.codeUnitAt(dataEnd) != _CharCodes.cr ||
            s.codeUnitAt(dataEnd + 1) != _CharCodes.lf) {
          return null;
        }

        final data = s.substring(dataStart, dataEnd);
        return (data, dataEnd + 2);

      case _CharCodes.asterisk:
        final headerEnd = s.indexOf(_crlf, start);
        if (headerEnd == -1) return null;

        final count = int.tryParse(s.substring(start + 1, headerEnd));
        if (count == null) return null;
        if (count == -1) return (null, headerEnd + 2);
        if (count == 0) return (<dynamic>[], headerEnd + 2);

        var position = headerEnd + 2;
        final values = <dynamic>[];
        for (var i = 0; i < count; i++) {
          final parsed = _parseWithConsumedAt(s, position);
          if (parsed == null) return null;
          values.add(parsed.$1);
          position = parsed.$2;
        }
        return (values, position);

      case _CharCodes.underscore:
        if (start + 3 > s.length) return null;
        if (s.codeUnitAt(start + 1) != _CharCodes.cr ||
            s.codeUnitAt(start + 2) != _CharCodes.lf) {
          return null;
        }
        return (null, start + 3);

      case _CharCodes.comma:
        final lineEnd = s.indexOf(_crlf, start);
        if (lineEnd == -1) return null;
        final value = double.tryParse(s.substring(start + 1, lineEnd));
        return (value, lineEnd + 2);

      case _CharCodes.hash:
        final boolLineEnd = s.indexOf(_crlf, start);
        if (boolLineEnd == -1) return null;
        final flag = s.substring(start + 1, boolLineEnd).toLowerCase();
        return (flag == 't', boolLineEnd + 2);

      case _CharCodes.leftParen:
        final lineEnd = s.indexOf(_crlf, start);
        if (lineEnd == -1) return null;
        final value = BigInt.tryParse(s.substring(start + 1, lineEnd));
        return (value, lineEnd + 2);

      default:
        return null;
    }
  }

  /// Parse one RESP value from [data], returning parsed value and consumed bytes.
  /// Bulk values are returned as [RedisBulkData] to preserve raw bytes.
  static (dynamic, int)? tryParseBytesWithConsumed(Uint8List data) {
    return _parseBytesWithConsumedAt(data, 0, data.length);
  }

  /// Parse one RESP value from [data] within [start, endExclusive).
  /// Returns consumed bytes relative to [start].
  static (dynamic, int)? tryParseBytesWithConsumedInRange(
    Uint8List data,
    int start,
    int endExclusive,
  ) {
    if (start < 0 || endExclusive < start || endExclusive > data.length) {
      return null;
    }
    return _parseBytesWithConsumedAt(data, start, endExclusive);
  }

  static (dynamic, int)? _parseBytesWithConsumedAt(
    Uint8List data,
    int start,
    int endExclusive,
  ) {
    if (start >= endExclusive) return null;

    final firstByte = data[start];
    switch (firstByte) {
      case _CharCodes.plus:
        final lineEnd = _findCrlf(data, start + 1, endExclusive);
        if (lineEnd == -1) return null;
        final value = _decodeAscii(data, start + 1, lineEnd);
        return (value.isEmpty ? null : value, lineEnd + 2 - start);

      case _CharCodes.colon:
        final lineEnd = _findCrlf(data, start + 1, endExclusive);
        if (lineEnd == -1) return null;
        final number = _parseAsciiInt(data, start + 1, lineEnd);
        return (number, lineEnd + 2 - start);

      case _CharCodes.minus:
        final errorLineEnd = _findCrlf(data, start + 1, endExclusive);
        if (errorLineEnd == -1) return null;
        final errorValue = _decodeAscii(data, start + 1, errorLineEnd);
        return (RedisServerErrorReply(errorValue), errorLineEnd + 2 - start);

      case _CharCodes.dollar:
        final headerEnd = _findCrlf(data, start + 1, endExclusive);
        if (headerEnd == -1) return null;

        final len = _parseAsciiInt(data, start + 1, headerEnd);
        if (len == null) return null;
        if (len == -1) {
          return (null, headerEnd + 2 - start);
        }

        final dataStart = headerEnd + 2;
        final dataEnd = dataStart + len;
        if (dataEnd + 2 > endExclusive) return null;
        if (data[dataEnd] != _CharCodes.cr ||
            data[dataEnd + 1] != _CharCodes.lf) {
          return null;
        }

        return (
          RedisBulkData(Uint8List.sublistView(data, dataStart, dataEnd)),
          dataEnd + 2 - start,
        );

      case _CharCodes.asterisk:
        final headerEnd = _findCrlf(data, start + 1, endExclusive);
        if (headerEnd == -1) return null;

        final count = _parseAsciiInt(data, start + 1, headerEnd);
        if (count == null) return null;
        if (count == -1) return (null, headerEnd + 2 - start);
        if (count == 0) return (<dynamic>[], headerEnd + 2 - start);

        var position = headerEnd + 2;
        final values = <dynamic>[];
        for (var i = 0; i < count; i++) {
          final parsed =
              _parseBytesWithConsumedAt(data, position, endExclusive);
          if (parsed == null) return null;
          values.add(parsed.$1);
          position += parsed.$2;
        }
        return (values, position - start);

      case _CharCodes.underscore:
        if (start + 3 > endExclusive) return null;
        if (data[start + 1] != _CharCodes.cr ||
            data[start + 2] != _CharCodes.lf) {
          return null;
        }
        return (null, 3);

      case _CharCodes.comma:
        final lineEnd = _findCrlf(data, start + 1, endExclusive);
        if (lineEnd == -1) return null;
        final number = double.tryParse(_decodeAscii(data, start + 1, lineEnd));
        return (number, lineEnd + 2 - start);

      case _CharCodes.hash:
        final lineEnd = _findCrlf(data, start + 1, endExclusive);
        if (lineEnd == -1) return null;
        final flag = _decodeAscii(data, start + 1, lineEnd).toLowerCase();
        return (flag == 't', lineEnd + 2 - start);

      case _CharCodes.bang:
        final headerEnd = _findCrlf(data, start + 1, endExclusive);
        if (headerEnd == -1) return null;
        final len = _parseAsciiInt(data, start + 1, headerEnd);
        if (len == null || len < 0) return null;
        final dataStart = headerEnd + 2;
        final dataEnd = dataStart + len;
        if (dataEnd + 2 > endExclusive) return null;
        if (data[dataEnd] != _CharCodes.cr ||
            data[dataEnd + 1] != _CharCodes.lf) {
          return null;
        }
        final message =
            utf8.decode(Uint8List.sublistView(data, dataStart, dataEnd));
        return (RedisServerErrorReply(message), dataEnd + 2 - start);

      case _CharCodes.equal:
        final headerEnd = _findCrlf(data, start + 1, endExclusive);
        if (headerEnd == -1) return null;
        final len = _parseAsciiInt(data, start + 1, headerEnd);
        if (len == null || len < 0) return null;
        final dataStart = headerEnd + 2;
        final dataEnd = dataStart + len;
        if (dataEnd + 2 > endExclusive) return null;
        if (data[dataEnd] != _CharCodes.cr ||
            data[dataEnd + 1] != _CharCodes.lf) {
          return null;
        }
        final full =
            utf8.decode(Uint8List.sublistView(data, dataStart, dataEnd));
        final split = full.indexOf(':');
        final value = split == -1 ? full : full.substring(split + 1);
        return (value, dataEnd + 2 - start);

      case _CharCodes.percent:
        final headerEnd = _findCrlf(data, start + 1, endExclusive);
        if (headerEnd == -1) return null;
        final count = _parseAsciiInt(data, start + 1, headerEnd);
        if (count == null || count < 0) return null;
        var position = headerEnd + 2;
        final values = <dynamic, dynamic>{};
        for (var i = 0; i < count; i++) {
          final keyParsed =
              _parseBytesWithConsumedAt(data, position, endExclusive);
          if (keyParsed == null) return null;
          position += keyParsed.$2;
          final valueParsed =
              _parseBytesWithConsumedAt(data, position, endExclusive);
          if (valueParsed == null) return null;
          position += valueParsed.$2;
          values[keyParsed.$1] = valueParsed.$1;
        }
        return (values, position - start);

      case _CharCodes.tilde:
        final headerEnd = _findCrlf(data, start + 1, endExclusive);
        if (headerEnd == -1) return null;
        final count = _parseAsciiInt(data, start + 1, headerEnd);
        if (count == null || count < 0) return null;
        var position = headerEnd + 2;
        final values = <dynamic>{};
        for (var i = 0; i < count; i++) {
          final parsed =
              _parseBytesWithConsumedAt(data, position, endExclusive);
          if (parsed == null) return null;
          position += parsed.$2;
          values.add(parsed.$1);
        }
        return (values, position - start);

      case _CharCodes.greaterThan:
        final headerEnd = _findCrlf(data, start + 1, endExclusive);
        if (headerEnd == -1) return null;
        final count = _parseAsciiInt(data, start + 1, headerEnd);
        if (count == null || count < 0) return null;
        var position = headerEnd + 2;
        final values = <dynamic>[];
        for (var i = 0; i < count; i++) {
          final parsed =
              _parseBytesWithConsumedAt(data, position, endExclusive);
          if (parsed == null) return null;
          values.add(parsed.$1);
          position += parsed.$2;
        }
        return (RedisPushData(values), position - start);

      case _CharCodes.leftParen:
        final lineEnd = _findCrlf(data, start + 1, endExclusive);
        if (lineEnd == -1) return null;
        final number = BigInt.tryParse(_decodeAscii(data, start + 1, lineEnd));
        return (number, lineEnd + 2 - start);

      case _CharCodes.pipe:
        final headerEnd = _findCrlf(data, start + 1, endExclusive);
        if (headerEnd == -1) return null;
        final count = _parseAsciiInt(data, start + 1, headerEnd);
        if (count == null || count < 0) return null;
        var position = headerEnd + 2;
        final attributes = <dynamic, dynamic>{};
        for (var i = 0; i < count; i++) {
          final keyParsed =
              _parseBytesWithConsumedAt(data, position, endExclusive);
          if (keyParsed == null) return null;
          position += keyParsed.$2;
          final valueParsed =
              _parseBytesWithConsumedAt(data, position, endExclusive);
          if (valueParsed == null) return null;
          position += valueParsed.$2;
          attributes[keyParsed.$1] = valueParsed.$1;
        }
        final next = _parseBytesWithConsumedAt(data, position, endExclusive);
        if (next == null) return null;
        position += next.$2;
        return (
          RedisAttributedData(attributes: attributes, data: next.$1),
          position - start,
        );

      default:
        return null;
    }
  }

  static int _findCrlf(Uint8List data, int start, int endExclusive) {
    for (var i = start; i + 1 < endExclusive; i++) {
      if (data[i] == _CharCodes.cr && data[i + 1] == _CharCodes.lf) {
        return i;
      }
    }
    return -1;
  }

  static String _decodeAscii(Uint8List data, int start, int end) {
    if (end <= start) return '';
    return ascii.decode(Uint8List.sublistView(data, start, end));
  }

  static int? _parseAsciiInt(Uint8List data, int start, int end) {
    if (end <= start) return null;
    return int.tryParse(_decodeAscii(data, start, end));
  }

  /// Advance [start] by [utf8Bytes] bytes in UTF-8 terms.
  /// Returns the resulting character index when exact, otherwise null.
  static int? _advanceByUtf8Bytes(String s, int start, int utf8Bytes) {
    var index = start;
    var consumed = 0;

    while (index < s.length && consumed < utf8Bytes) {
      final unit = s.codeUnitAt(index);
      int width;

      if (unit <= 0x7F) {
        width = 1;
      } else if (unit <= 0x7FF) {
        width = 2;
      } else if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (index + 1 >= s.length) return null;
        final low = s.codeUnitAt(index + 1);
        if (low < 0xDC00 || low > 0xDFFF) return null;
        width = 4;
        index += 1;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return null;
      } else {
        width = 3;
      }

      if (consumed + width > utf8Bytes) return null;
      consumed += width;
      index += 1;
    }

    if (consumed != utf8Bytes) return null;
    return index;
  }
}
