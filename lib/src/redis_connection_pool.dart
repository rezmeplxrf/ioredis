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

  /// Send command to connection
  Future<dynamic> sendCommand(List<String> commandList) {
    /// If there is idle connection use idle connection
    final idleConnection = _getIdleConnection();
    if (idleConnection != null) {
      // reset to prevent destroying, since connection is not idle anymore;
      _resetTimer(idleConnection.key);
      return idleConnection.value.sendCommand(commandList);
    }

    /// If no idle connection create new connection if not over maxConnection yet.
    if (_poolConnections.length < option.maxConnection - 1) {
      final connId = _getNewIdForPoolConnection();
      final conn = RedisConnection(option);
      _poolConnections[connId] = conn;
      // reset to prevent destroying, since connection is not idle anymore;
      _resetTimer(connId);
      return conn.sendCommand(commandList);
    }

    /// If no idle connection and not able to create new connection,
    /// use random connection to sent command
    final randomConnection = _getRandomConnection();
    if (randomConnection != null) {
      _resetTimer(randomConnection.key);
      return randomConnection.value.sendCommand(commandList);
    }

    /// If there is no connection with connected state, use mainConnection
    return mainConnection.sendCommand(commandList);
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

    // Get all connected connections first
    final connectedConnections = <MapEntry<int, RedisConnection>>[];
    for (final entry in _poolConnections.entries) {
      if (entry.value.status == RedisConnectionStatus.connected) {
        connectedConnections.add(entry);
      }
    }

    if (connectedConnections.isEmpty) return null;

    // Return a random connected connection
    final randomIndex = _random.nextInt(connectedConnections.length);
    return connectedConnections[randomIndex];
  }

  /// get new id for pool connection
  int _getNewIdForPoolConnection() {
    if (_poolConnections.isEmpty) return 1;

    // More efficient approach: find the maximum key and increment
    int maxKey = 0;
    for (final key in _poolConnections.keys) {
      if (key > maxKey) maxKey = key;
    }

    // Reset to 1 if we reach the limit, otherwise increment
    return maxKey > 1000000 ? 1 : maxKey + 1;
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
