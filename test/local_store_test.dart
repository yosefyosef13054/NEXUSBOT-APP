import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/local_store.dart';

void main() {
  group('MemoryLocalStore', () {
    test('round-trips documents, lists keys by prefix and clears', () async {
      final store = MemoryLocalStore();
      await store.write('cache:u1:sessions', {
        'items': [1, 2],
      });
      await store.write('cache:u1:messages:s1', {'items': []});
      await store.write('sendqueue:u1', {'items': []});
      expect(await store.read('cache:u1:sessions'), {
        'items': [1, 2],
      });
      expect(await store.read('missing'), isNull);
      expect(await store.keys(prefix: 'cache:'), ['cache:u1:messages:s1', 'cache:u1:sessions']);
      await store.delete('cache:u1:sessions');
      expect(await store.read('cache:u1:sessions'), isNull);
      await store.clear();
      expect(await store.keys(), isEmpty);
    });

    test('hands out copies, never shared state', () async {
      final store = MemoryLocalStore();
      final value = {'n': 1};
      await store.write('k', value);
      value['n'] = 2;
      final read = (await store.read('k'))!;
      expect(read['n'], 1);
      read['n'] = 3;
      expect((await store.read('k'))!['n'], 1);
    });
  });

  group('JsonFileLocalStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('nexusbot-store-');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    JsonFileLocalStore store() => JsonFileLocalStore(baseDirectory: () async => dir);

    test('persists documents as one JSON file per key', () async {
      final s = store();
      await s.write('cache:u1:sessions', {
        'items': ['a'],
      });
      await s.write('sendqueue:u1', {'items': []});
      expect(s.isPersistent, isTrue);
      final files = Directory('${dir.path}/nexusbot_cache').listSync().whereType<File>().toList();
      expect(files, hasLength(2));
      expect(files.every((f) => f.path.endsWith('.json')), isTrue);
      expect(files.any((f) => f.path.endsWith('.tmp')), isFalse, reason: 'renamed into place');

      // A fresh instance over the same directory sees everything.
      final again = store();
      expect(await again.read('cache:u1:sessions'), {
        'items': ['a'],
      });
      expect(await again.keys(prefix: 'cache:'), ['cache:u1:sessions']);
      expect(await again.keys(), ['cache:u1:sessions', 'sendqueue:u1']);
      await again.delete('cache:u1:sessions');
      expect(await again.read('cache:u1:sessions'), isNull);
      await again.clear();
      expect(await again.keys(), isEmpty);
    });

    test('a corrupt or foreign file reads as absent and is dropped', () async {
      final s = store();
      await s.write('k', {'v': 1});
      final file = File('${dir.path}/nexusbot_cache/${JsonFileLocalStore.fileNameFor('k')}');
      await file.writeAsString('{not json');
      expect(await s.read('k'), isNull);
      expect(await file.exists(), isFalse);

      await s.write('k', {'v': 1});
      // Same file name, different key inside: not ours.
      await file.writeAsString('{"key":"other","value":{"v":2}}');
      expect(await s.read('k'), isNull);
    });

    test('file names are safe and collision free', () {
      expect(
        JsonFileLocalStore.fileNameFor('cache:u/1:sessions'),
        matches(r'^[A-Za-z0-9._-]+\.json$'),
      );
      expect(
        JsonFileLocalStore.fileNameFor('a:b'),
        isNot(JsonFileLocalStore.fileNameFor('a_b')),
        reason: 'the hash suffix tells sanitised twins apart',
      );
      expect(JsonFileLocalStore.fnv1a('hello'), 0x4f9f2cab);
    });

    test('falls back to memory when the directory cannot be resolved', () async {
      final s = JsonFileLocalStore(baseDirectory: () async => throw StateError('no platform'));
      await s.write('k', {'v': 1});
      expect(s.isPersistent, isFalse);
      expect(await s.read('k'), {'v': 1});
    });
  });
}
