import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_client.dart';
import 'package:nexusbot/features/auth/auth_models.dart';
import 'package:nexusbot/features/push/devices_repository.dart';
import 'package:nexusbot/features/push/push_registrar.dart';
import 'package:nexusbot/features/push/push_router.dart';
import 'package:nexusbot/features/push/push_service.dart';

import 'helpers/fakes.dart';

class FakePushService implements PushService {
  FakePushService({this.token = 'tok-123', this.available = true});

  String? token;
  bool available;
  int tokenCalls = 0;
  final _payloads = StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get isAvailable => available;

  @override
  String get platform => 'android';

  @override
  Future<String?> getToken() async {
    tokenCalls++;
    return token;
  }

  @override
  Stream<Map<String, dynamic>> get payloads => _payloads.stream;

  @override
  Future<void> dispose() => _payloads.close();
}

class FakeDevicesRepository extends DevicesRepository {
  FakeDevicesRepository() : super(ApiClient.create(MemoryTokenStorage()));

  final registered = <({String platform, String token, String? appVersion, String? locale})>[];
  final unregistered = <String>[];
  Object? error;

  @override
  Future<Device> register({
    required String platform,
    required String token,
    String? appVersion,
    String? locale,
  }) async {
    final e = error;
    if (e != null) throw e;
    registered.add((platform: platform, token: token, appVersion: appVersion, locale: locale));
    return Device(id: 'd1', platform: platform, tokenSuffix: token.substring(token.length - 3));
  }

  @override
  Future<void> unregister(String token) async {
    final e = error;
    if (e != null) throw e;
    unregistered.add(token);
  }
}

const user = User(id: 'u1', email: 'a@b.com', role: 'user');

void main() {
  group('PushRouter', () {
    test('a generation_done payload opens the chat with the generation to attach', () {
      final visited = <String>[];
      final router = PushRouter(navigate: visited.add);
      final handled = router.handlePushPayload({
        'type': 'generation_done',
        'session_id': 's1',
        'generation_id': 'g1',
      });
      expect(handled, isTrue);
      expect(visited, ['/chat/s1?generation=g1']);
    });

    test('a payload without a generation still opens the chat', () {
      expect(
        PushRouter.locationFor({'type': 'generation_done', 'session_id': 's1'}),
        '/chat/s1',
      );
      expect(
        PushRouter.locationFor(
          {'type': 'generation_done', 'session_id': 's1', 'generation_id': ''},
        ),
        '/chat/s1',
      );
    });

    test('unknown or malformed payloads are ignored', () {
      final visited = <String>[];
      final router = PushRouter(navigate: visited.add);
      expect(router.handlePushPayload({'type': 'marketing'}), isFalse);
      expect(router.handlePushPayload({'type': 'generation_done'}), isFalse);
      expect(router.handlePushPayload({'session_id': 's1'}), isFalse);
      expect(router.handlePushPayload({'type': 42, 'session_id': 's1'}), isFalse);
      expect(router.handlePushPayload({}), isFalse);
      expect(visited, isEmpty);
    });

    test('PushPayload parses the fields it understands', () {
      final p =
          PushPayload.parse({'type': 'generation_done', 'session_id': 's1', 'generation_id': 'g1'});
      expect(p?.isGenerationDone, isTrue);
      expect(p?.sessionId, 's1');
      expect(p?.generationId, 'g1');
      expect(PushPayload.parse({'type': 'other', 'session_id': 's1'})?.isGenerationDone, isFalse);
      expect(PushPayload.parse({'type': ''}), isNull);
    });
  });

  group('PushRegistrar', () {
    test('registers the token once per user and unregisters at sign-out', () async {
      final service = FakePushService();
      final repo = FakeDevicesRepository();
      final registrar = PushRegistrar(
        service: service,
        repository: () async => repo,
        appVersion: '1.2.3',
        locale: 'en-GB',
      );
      await registrar.sync(user);
      expect(
        repo.registered.single,
        (
          platform: 'android',
          token: 'tok-123',
          appVersion: '1.2.3',
          locale: 'en-GB',
        ),
      );
      expect(registrar.registeredToken, 'tok-123');

      await registrar.sync(user);
      expect(repo.registered, hasLength(1), reason: 'same user, already registered');
      expect(service.tokenCalls, 1);

      await registrar.sync(null);
      expect(repo.unregistered, ['tok-123']);
      expect(registrar.registeredToken, isNull);

      await registrar.sync(const User(id: 'u2', email: 'c@d.com', role: 'user'));
      expect(repo.registered, hasLength(2), reason: 'a new user registers again');
    });

    test('does nothing without a push provider or a token', () async {
      final repo = FakeDevicesRepository();
      await PushRegistrar(service: const NoopPushService(), repository: () async => repo)
          .sync(user);
      expect(repo.registered, isEmpty);

      final noToken = FakePushService(token: null);
      await PushRegistrar(service: noToken, repository: () async => repo).sync(user);
      expect(repo.registered, isEmpty);
      expect(noToken.tokenCalls, 1);
    });

    test('a failed registration never throws', () async {
      final repo = FakeDevicesRepository()
        ..error = ApiException(code: 'network_error', message: 'offline');
      final registrar = PushRegistrar(service: FakePushService(), repository: () async => repo);
      await registrar.sync(user);
      expect(registrar.registeredToken, isNull, reason: 'retried on the next sign-in');
    });

    test('the FCM stub is unavailable until Firebase is wired', () {
      expect(FcmPushService().isAvailable, isFalse);
      expect(const NoopPushService().isAvailable, isFalse);
      expect(currentPushPlatform(), isIn(['ios', 'android', 'web']));
    });
  });
}
