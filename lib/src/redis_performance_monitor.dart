// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';

/// Performance monitoring utilities for Redis operations
class RedisPerformanceMonitor {
  static final Map<String, List<int>> _operationTimes = <String, List<int>>{};
  static const int _maxSamples = 1000; // Keep last 1000 samples per operation

  /// Time an operation and collect performance metrics
  static Future<T> timeOperation<T>(
      String operationName, Future<T> Function() operation) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await operation();
      return result;
    } finally {
      stopwatch.stop();
      _recordOperationTime(operationName, stopwatch.elapsedMicroseconds);
    }
  }

  /// Record operation time
  static void _recordOperationTime(String operationName, int microseconds) {
    _operationTimes.putIfAbsent(operationName, () => <int>[]);
    final times = _operationTimes[operationName]!;

    times.add(microseconds);

    // Keep only recent samples
    if (times.length > _maxSamples) {
      times.removeRange(0, times.length - _maxSamples);
    }
  }

  /// Get performance statistics for an operation
  static PerformanceStats? getStats(String operationName) {
    final times = _operationTimes[operationName];
    if (times == null || times.isEmpty) return null;

    final sortedTimes = List<int>.from(times)..sort();
    final count = sortedTimes.length;

    return PerformanceStats(
      operationName: operationName,
      count: count,
      averageMicros: sortedTimes.reduce((a, b) => a + b) ~/ count,
      minMicros: sortedTimes.first,
      maxMicros: sortedTimes.last,
      p50Micros: sortedTimes[count ~/ 2],
      p95Micros: sortedTimes[(count * 0.95).round() - 1],
      p99Micros: sortedTimes[(count * 0.99).round() - 1],
    );
  }

  /// Get all performance statistics
  static Map<String, PerformanceStats> getAllStats() {
    final stats = <String, PerformanceStats>{};
    for (final operationName in _operationTimes.keys) {
      final stat = getStats(operationName);
      if (stat != null) {
        stats[operationName] = stat;
      }
    }
    return stats;
  }

  /// Clear all performance data
  static void clear() {
    _operationTimes.clear();
  }

  /// Reset statistics for a specific operation
  static void clearOperation(String operationName) {
    _operationTimes.remove(operationName);
  }
}

/// Performance statistics for Redis operations
class PerformanceStats {
  const PerformanceStats({
    required this.operationName,
    required this.count,
    required this.averageMicros,
    required this.minMicros,
    required this.maxMicros,
    required this.p50Micros,
    required this.p95Micros,
    required this.p99Micros,
  });

  final String operationName;
  final int count;
  final int averageMicros;
  final int minMicros;
  final int maxMicros;
  final int p50Micros;
  final int p95Micros;
  final int p99Micros;

  /// Get average time in milliseconds
  double get averageMs => averageMicros / 1000.0;

  /// Get minimum time in milliseconds
  double get minMs => minMicros / 1000.0;

  /// Get maximum time in milliseconds
  double get maxMs => maxMicros / 1000.0;

  /// Get P50 (median) time in milliseconds
  double get p50Ms => p50Micros / 1000.0;

  /// Get P95 time in milliseconds
  double get p95Ms => p95Micros / 1000.0;

  /// Get P99 time in milliseconds
  double get p99Ms => p99Micros / 1000.0;

  @override
  String toString() {
    return 'PerformanceStats('
        'operation: $operationName, '
        'count: $count, '
        'avg: ${averageMs.toStringAsFixed(2)}ms, '
        'min: ${minMs.toStringAsFixed(2)}ms, '
        'max: ${maxMs.toStringAsFixed(2)}ms, '
        'p50: ${p50Ms.toStringAsFixed(2)}ms, '
        'p95: ${p95Ms.toStringAsFixed(2)}ms, '
        'p99: ${p99Ms.toStringAsFixed(2)}ms'
        ')';
  }
}
