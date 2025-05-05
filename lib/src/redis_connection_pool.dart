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
    if (_getTotalPoolConnections() < option.maxConnection - 1) {
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
    final connections = _poolConnections.entries
        .where((MapEntry<int, RedisConnection> element) =>
            element.value.isBusy == false &&
            element.value.status == RedisConnectionStatus.connected)
        .toList();
    return connections.isEmpty ? null : connections.first;
  }

  /// get random connection with connected state to send command
  MapEntry<int, RedisConnection>? _getRandomConnection() {
    if (_poolConnections.isEmpty) return null;
    final keys = _poolConnections.keys.toList();

    final randomIndex = Random().nextInt(keys.length);
    final randomKey = keys[randomIndex];

    final connections = _poolConnections.entries
        .where((MapEntry<int, RedisConnection> element) =>
            element.key == randomKey &&
            element.value.status == RedisConnectionStatus.connected)
        .toList();

    return connections.isEmpty ? null : connections.first;
  }

  /// get current total pool connections
  int _getTotalPoolConnections() {
    final keys = _poolConnections.keys.toList();
    return keys.length;
  }

  /// get new id for pool connection
  int _getNewIdForPoolConnection() {
    final keys = _poolConnections.keys.toList();

    /// sort max -> min to get the biggest number
    keys.sort((int a, int b) => b.compareTo(a));

    if (keys.isNotEmpty) {
      /// if max number is greater than 1000000, reset to 1,
      /// else +1 to max number
      return keys[0] > 1000000 ? 1 : keys[0] + 1;
    } else {
      /// initial id to 1
      return 1;
    }
  }

  /// Reset timer
  void _resetTimer(int connId) {
    final timer = _poolConnectionTimers[connId];
    if (timer != null) {
      timer.cancel();
    }
    _poolConnectionTimers[connId] = Timer(option.idleTimeout, () {
      _destroyAndRemove(connId);
    });
  }

  /// remove connection
  void _destroyAndRemove(int connId) {
    final c = _poolConnections[connId];
    if (c != null) {
      c.destroy();
      // remove only after destroyed
      _poolConnections.remove(connId);
    }
  }
}
