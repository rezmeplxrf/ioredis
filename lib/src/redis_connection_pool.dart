import 'dart:async';
import 'dart:math';

import 'package:ioredis/ioredis.dart';

class RedisConnectionPool {
  /// Class constructor
  RedisConnectionPool(this.option, this.mainConnection);

  /// Main connection to send command
  final RedisConnection mainConnection;

  /// Pool connections stored in memory
  final Map<int, RedisConnection> _poolConnections = <int, RedisConnection>{};

  /// Pool connections timer to remove from pool after idle.
  final Map<int, Timer> _poolConnectionTimers = <int, Timer>{};

  /// Redis option
  final RedisOptions option;

  /// Cache for random number generation
  final Random _random = Random();

  /// Incremental pool id allocator.
  int _nextConnectionId = 1;

  /// Send command to connection
  Future<dynamic> sendCommand(List<String> commandList, {Duration? timeout}) {
    /// If there is idle connection use idle connection
    final idleConnection = _getIdleConnection();
    if (idleConnection != null) {
      // reset to prevent destroying, since connection is not idle anymore;
      _resetTimer(idleConnection.key);
      return idleConnection.value.sendCommand(commandList, timeout: timeout);
    }

    /// If no idle connection create new connection if not over maxConnection yet.
    if (_poolConnections.length < option.maxConnection) {
      final connId = _getNewIdForPoolConnection();
      final conn = RedisConnection(option);
      _poolConnections[connId] = conn;
      // reset to prevent destroying, since connection is not idle anymore;
      _resetTimer(connId);
      return conn.sendCommand(commandList, timeout: timeout);
    }

    /// If no idle connection and not able to create new connection,
    /// use random connection to sent command
    final randomConnection = _getRandomConnection();
    if (randomConnection != null) {
      _resetTimer(randomConnection.key);
      return randomConnection.value.sendCommand(commandList, timeout: timeout);
    }

    /// If there is no connection with connected state, use mainConnection
    return mainConnection.sendCommand(commandList, timeout: timeout);
  }

  /// get not busy connection with connected state to send command
  MapEntry<int, RedisConnection>? _getIdleConnection() {
    // Use more efficient iteration for better performance
    for (final entry in _poolConnections.entries) {
      if (!entry.value.isBusy &&
          entry.value.status == RedisConnectionStatus.connected) {
        return entry;
      }
    }
    return null;
  }

  /// get random connection with connected state to send command
  MapEntry<int, RedisConnection>? _getRandomConnection() {
    if (_poolConnections.isEmpty) return null;

    // Reservoir sampling over connected entries to avoid temporary list allocation.
    MapEntry<int, RedisConnection>? selected;
    var seen = 0;
    for (final entry in _poolConnections.entries) {
      if (entry.value.status != RedisConnectionStatus.connected) {
        continue;
      }
      seen++;
      if (_random.nextInt(seen) == 0) {
        selected = entry;
      }
    }
    return selected;
  }

  /// get new id for pool connection
  int _getNewIdForPoolConnection() {
    final start = _nextConnectionId;
    while (_poolConnections.containsKey(_nextConnectionId)) {
      _nextConnectionId =
          _nextConnectionId >= 1000000 ? 1 : _nextConnectionId + 1;
      if (_nextConnectionId == start) {
        throw StateError('Unable to allocate connection id');
      }
    }
    final allocated = _nextConnectionId;
    _nextConnectionId =
        _nextConnectionId >= 1000000 ? 1 : _nextConnectionId + 1;
    return allocated;
  }

  /// Reset timer
  void _resetTimer(int connId) {
    final timer = _poolConnectionTimers[connId];
    timer?.cancel();

    _poolConnectionTimers[connId] = Timer(option.idleTimeout, () {
      _destroyAndRemove(connId);
    });
  }

  /// remove connection
  void _destroyAndRemove(int connId) {
    final connection = _poolConnections[connId];
    if (connection != null) {
      connection.destroy();
      _poolConnections.remove(connId);
    }

    // Also clean up the timer
    final timer = _poolConnectionTimers[connId];
    if (timer != null) {
      timer.cancel();
      _poolConnectionTimers.remove(connId);
    }
  }

  /// Clean up all connections and timers
  void dispose() {
    for (final timer in _poolConnectionTimers.values) {
      timer.cancel();
    }
    _poolConnectionTimers.clear();

    for (final connection in _poolConnections.values) {
      connection.destroy();
    }
    _poolConnections.clear();
  }
}
