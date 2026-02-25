Cluster/Sentinel support (node discovery, slot cache, auto MOVED/ASK redirection, failover handling).
RESP3 support (HELLO 3, push types, maps/sets/attributes).
Full command surface wrappers (hash/list/set/zset/streams/geo/script/watch/unwatch/discard/etc.).
Binary-safe API (Uint8List keys/values, raw reply mode).
Re-subscribe-on-reconnect guarantees for pub/sub, plus sharded pub/sub (SSUBSCRIBE).
SCAN iterators/streaming cursors for large keyspaces.
Script helpers (SCRIPT LOAD, EVALSHA, caching helpers).
URL-based connection config (redis://, rediss://) and richer TLS options (CA/cert/key/SNI).
Better transaction ergonomics (watch flow, pinned connections, atomic helper APIs).
Observability hooks (command latency metrics, lifecycle events, structured logging).