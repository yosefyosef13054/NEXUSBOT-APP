import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// A small key → JSON document store that backs the offline cache and the
/// send queue.
///
/// Abstract so tests run against [MemoryLocalStore]; the app uses
/// [JsonFileLocalStore], one JSON file per key under the application support
/// directory (`path_provider`). Values are plain JSON maps: callers own the
/// (de)serialisation, the store never interprets them.
abstract class LocalStore {
  /// The document stored under [key], or null when there is none (or it is
  /// unreadable — a corrupt file is dropped, never surfaced).
  Future<Map<String, dynamic>?> read(String key);

  /// Replaces the document under [key].
  Future<void> write(String key, Map<String, dynamic> value);

  Future<void> delete(String key);

  /// Every stored key, optionally only those starting with [prefix].
  Future<List<String>> keys({String prefix = ''});

  /// Drops everything (sign-out).
  Future<void> clear();
}

/// In-memory [LocalStore] — tests, and the fallback when the file system is
/// unavailable.
class MemoryLocalStore implements LocalStore {
  final Map<String, Map<String, dynamic>> _docs = {};

  /// Snapshot of what is stored (for assertions).
  Map<String, Map<String, dynamic>> get documents => Map.unmodifiable(_docs);

  int writes = 0;

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final doc = _docs[key];
    // Decode / encode so callers never share mutable state with the store.
    return doc == null ? null : jsonDecode(jsonEncode(doc)) as Map<String, dynamic>;
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    writes++;
    _docs[key] = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }

  @override
  Future<void> delete(String key) async {
    _docs.remove(key);
  }

  @override
  Future<List<String>> keys({String prefix = ''}) async =>
      _docs.keys.where((k) => k.startsWith(prefix)).toList()..sort();

  @override
  Future<void> clear() async => _docs.clear();
}

/// [LocalStore] on the file system: `<app support>/nexusbot_cache/<file>.json`,
/// one file per key, each holding `{"key": …, "value": …}` so the key list
/// can be rebuilt from the directory. Writes go to a temporary file first and
/// are renamed into place, so a crash mid-write never leaves a half document.
///
/// The directory is resolved lazily; when `path_provider` is unavailable
/// (`flutter test`, an unsupported platform) the store silently degrades to
/// memory so the app keeps working without a cache.
class JsonFileLocalStore implements LocalStore {
  JsonFileLocalStore({
    Future<Directory> Function()? baseDirectory,
    this.subdirectory = 'nexusbot_cache',
  }) : _baseDirectory = baseDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDirectory;
  final String subdirectory;

  Directory? _dir;
  bool _resolved = false;
  final MemoryLocalStore _fallback = MemoryLocalStore();

  /// Whether reads and writes hit the file system (false = memory fallback).
  bool get isPersistent => _dir != null;

  Future<Directory?> _directory() async {
    if (_resolved) return _dir;
    _resolved = true;
    try {
      final base = await _baseDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}$subdirectory');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
    } catch (_) {
      _dir = null; // No platform channel / read-only storage: memory only.
    }
    return _dir;
  }

  /// `sessions:u1:o1` → `sessions_u1_o1-<fnv1a>.json`: readable, collision
  /// free and valid on every file system.
  static String fileNameFor(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final head = safe.length > 80 ? safe.substring(0, 80) : safe;
    return '$head-${fnv1a(key).toRadixString(16)}.json';
  }

  /// 32-bit FNV-1a over the UTF-8 bytes of [input] — stable across Dart
  /// versions (unlike `String.hashCode`).
  static int fnv1a(String input) {
    var hash = 0x811C9DC5;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  File _fileFor(Directory dir, String key) =>
      File('${dir.path}${Platform.pathSeparator}${fileNameFor(key)}');

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final dir = await _directory();
    if (dir == null) return _fallback.read(key);
    final file = _fileFor(dir, key);
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['key'] == key && decoded['value'] is Map) {
        return (decoded['value'] as Map).cast<String, dynamic>();
      }
    } catch (_) {
      // Corrupt or unreadable: treat as absent (and drop it below).
    }
    try {
      await file.delete();
    } catch (_) {
      // Best effort.
    }
    return null;
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    final dir = await _directory();
    if (dir == null) return _fallback.write(key, value);
    final file = _fileFor(dir, key);
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(jsonEncode({'key': key, 'value': value}), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Out of space / read-only: the cache is a convenience, never fatal.
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // Ignore.
      }
    }
  }

  @override
  Future<void> delete(String key) async {
    final dir = await _directory();
    if (dir == null) return _fallback.delete(key);
    try {
      final file = _fileFor(dir, key);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Ignore.
    }
  }

  @override
  Future<List<String>> keys({String prefix = ''}) async {
    final dir = await _directory();
    if (dir == null) return _fallback.keys(prefix: prefix);
    final out = <String>[];
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final decoded = jsonDecode(await entity.readAsString());
          final key = decoded is Map ? decoded['key'] : null;
          if (key is String && key.startsWith(prefix)) out.add(key);
        } catch (_) {
          // Skip unreadable files.
        }
      }
    } catch (_) {
      // Directory vanished.
    }
    return out..sort();
  }

  @override
  Future<void> clear() async {
    final dir = await _directory();
    if (dir == null) return _fallback.clear();
    try {
      await for (final entity in dir.list()) {
        if (entity is File) await entity.delete();
      }
    } catch (_) {
      // Ignore.
    }
  }
}

final localStoreProvider = Provider<LocalStore>((_) => JsonFileLocalStore());
