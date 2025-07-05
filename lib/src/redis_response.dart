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

enum RedisType {
  normal('normal'),
  subscriber('publisher'),
  publisher('publisher');

  const RedisType(this.name);
  final String name;
}

class RedisResponse {
  static bool ok(String? s) {
    return s == 'OK' || s == '+OK';
  }

  static bool isSimpleString(String s) {
    return s.startsWith(RedisResponseConstant.simpleString.name);
  }

  static String? toSimpleString(String s) {
    final val = s.substring(1).replaceFirst('\r\n', '');
    if (val.isEmpty) return null;
    return val;
  }

  static String? toBulkString(String s) {
    // Parse Redis bulk string format: $<length>\r\n<data>\r\n
    if (!s.startsWith('\$')) return null;
    
    final firstCrlfIndex = s.indexOf('\r\n');
    if (firstCrlfIndex == -1) return null;
    
    final lengthStr = s.substring(1, firstCrlfIndex);
    final length = int.tryParse(lengthStr);
    
    if (length == null) return null;
    
    // Check for null bulk string
    if (length == -1) return null;
    
    // Extract the data part based on the specified length
    final dataStartIndex = firstCrlfIndex + 2;
    final dataEndIndex = dataStartIndex + length;
    
    // Make sure we have enough data
    if (s.length < dataEndIndex) return null;
    
    return s.substring(dataStartIndex, dataEndIndex);
  }

  static List<String?> toArrayString(String s) {
    final listOfData = s.split('\r\n');
    final elements = <String?>[];

    final count = int.parse(listOfData[0].substring(1));
    var currentIndex = 0;
    var i = 0;

    var type = '';

    while (currentIndex < count) {
      i++;
      final element = '$type${listOfData[i]}';
      if (type.isEmpty && (isBulkString(element))) {
        type = '$element\r\n';
      } else if (type.isNotEmpty) {
        elements.add(transform(element) as String?);
        type = '';
        currentIndex++;
      } else {
        elements.add(transform(element) as String?);
        currentIndex++;
      }
    }
    return elements;
  }

  String? toErrorString(String s) {
    return s.substring(1, s.length - 2);
  }

  static bool isError(String s) {
    return s.startsWith(RedisResponseConstant.error.name);
  }

  static bool isBulkString(String s) {
    return s.startsWith(RedisResponseConstant.bulkString.name);
  }

  static bool isInteger(String s) {
    return s.startsWith(RedisResponseConstant.integer.name);
  }

  static bool isArray(String s) {
    return s.startsWith(RedisResponseConstant.array.name);
  }

  static dynamic transform(String? s) {
    if (s == null || s.isEmpty) return null;
    if (ok(s)) {
      return 'OK';
    } else if (isSimpleString(s)) {
      return toSimpleString(s);
    } else if (isError(s)) {
      return toSimpleString(s);
    } else if (isInteger(s)) {
      return toSimpleString(s);
    } else if (isBulkString(s)) {
      return toBulkString(s);
    } else if (isArray(s)) {
      return toArrayString(s);
    }
    return null;
  }
}
