import 'dart:convert';

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
  static const int cr = 13; // '\r'
  static const int lf = 10; // '\n'
}

enum RedisType {
  normal('normal'),
  subscriber('publisher'),
  publisher('publisher');

  const RedisType(this.name);
  final String name;
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

    // Find \r\n more efficiently
    final crlfIndex = s.indexOf(_crlf, 1);
    if (crlfIndex == -1) {
      // No CRLF found, take everything after first character
      final val = s.substring(1);
      return val.isEmpty ? null : val;
    }

    final val = s.substring(1, crlfIndex);
    return val.isEmpty ? null : val;
  }

  static String? toBulkString(String s) {
    if (s.length < 4) return null; // Minimum: $0\r\n\r\n

    // Find first \r\n more efficiently
    var crlfIndex = -1;
    for (var i = 1; i < s.length - 1; i++) {
      if (s.codeUnitAt(i) == _CharCodes.cr &&
          s.codeUnitAt(i + 1) == _CharCodes.lf) {
        crlfIndex = i;
        break;
      }
    }

    if (crlfIndex == -1) return null;

    final lengthStr = s.substring(1, crlfIndex);
    final length = int.tryParse(lengthStr);
    if (length == null) return null;

    // Check for null bulk string
    if (length == -1) return null;

    // Extract the data part more efficiently
    final dataStartIndex = crlfIndex + 2;
    if (dataStartIndex >= s.length) return null;

    // For better UTF-8 handling, we need to work with bytes
    final bytes = utf8.encode(s);
    final headerBytes = utf8.encode(s.substring(0, dataStartIndex));
    final dataEndByteIndex = headerBytes.length + length;

    // Make sure we have enough bytes
    if (bytes.length < dataEndByteIndex) return null;

    // Extract the data bytes and decode back to string
    final dataBytes = bytes.sublist(headerBytes.length, dataEndByteIndex);
    return utf8.decode(dataBytes);
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

    // Early return for OK responses
    if (s == _okResponse || s == _plusOkResponse) return _okResponse;

    // Use codeUnitAt for faster type checking
    final firstChar = s.codeUnitAt(0);

    switch (firstChar) {
      case _CharCodes.plus:
        return toSimpleString(s);
      case _CharCodes.minus:
        return toSimpleString(s);
      case _CharCodes.colon:
        return toSimpleString(s);
      case _CharCodes.dollar:
        return toBulkString(s);
      case _CharCodes.asterisk:
        return toArrayString(s);
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
      case _CharCodes.minus:
      case _CharCodes.colon:
        final lineEnd = s.indexOf(_crlf, start);
        if (lineEnd == -1) return null;
        final value = s.substring(start + 1, lineEnd);
        return (value.isEmpty ? null : value, lineEnd + 2);

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

      default:
        return null;
    }
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
