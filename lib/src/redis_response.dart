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

  static List<String?> toArrayString(String s) {
    if (s.length < 4) return []; // Minimum: *0\r\n

    // Find first \r\n efficiently
    var crlfIndex = -1;
    for (var i = 1; i < s.length - 1; i++) {
      if (s.codeUnitAt(i) == _CharCodes.cr &&
          s.codeUnitAt(i + 1) == _CharCodes.lf) {
        crlfIndex = i;
        break;
      }
    }

    if (crlfIndex == -1) return [];

    final countStr = s.substring(1, crlfIndex);
    final count = int.tryParse(countStr);
    if (count == null) return [];
    if (count <= 0) return List<String?>.filled(count == 0 ? 0 : 0, null);

    final elements = <String?>[];
    var position = crlfIndex + 2;
    var currentIndex = 0;

    while (currentIndex < count && position < s.length) {
      // Find the next element's end
      final nextCrlfIndex = s.indexOf(_crlf, position);
      if (nextCrlfIndex == -1) break;

      final element = s.substring(position, nextCrlfIndex + 2);

      if (element.isNotEmpty && element.codeUnitAt(0) == _CharCodes.dollar) {
        // This is a bulk string
        final lengthStr = element.substring(1, element.length - 2);
        final length = int.tryParse(lengthStr);

        if (length == null) break;

        if (length == -1) {
          // Null bulk string
          elements.add(null);
          position = nextCrlfIndex + 2;
          currentIndex++;
        } else {
          // Non-null bulk string - need to get the actual data
          final dataStartIndex = nextCrlfIndex + 2;
          if (dataStartIndex >= s.length) break;

          // Find the end of the data (another \r\n after the data)
          final dataEndIndex = dataStartIndex + length;
          if (dataEndIndex + 2 > s.length) break;

          final data = s.substring(dataStartIndex, dataEndIndex);
          elements.add(data);
          position = dataEndIndex + 2; // Skip the final \r\n
          currentIndex++;
        }
      } else {
        // This is a simple element
        elements.add(transform(element) as String?);
        position = nextCrlfIndex + 2;
        currentIndex++;
      }
    }

    return elements;
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
}
