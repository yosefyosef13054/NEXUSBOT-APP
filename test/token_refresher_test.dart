import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/core/api_exception.dart';
import 'package:nexusbot/core/auth_session.dart';
import 'package:nexusbot/features/auth/auth_models.dart';

import 'helpers/fakes.dart';

/// Builds an unsigned JWT-shaped token (header.payload.signature) whose
/// payload carries [claims] — base64url without padding, like real tokens.
String makeJwt(Map<String, Object?> claims) {
  String enc(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.${enc(claims)}.sig';
}

TokenPair pair(String access, String refresh) =>
    TokenPair(accessToken: access, refreshToken: refresh, expiresIn: 900);

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);
  int secondsFromNow(int s) => now.add(Duration(seconds: s)).millisecondsSinceEpoch ~/ 1000;

  group('JWT decoding', () {
    test('reads exp as a UTC DateTime', () {
      final token = makeJwt({'sub': 'u1', 'exp': secondsFromNow(300)});
      expect(TokenRefresher.jwtExpiry(token), now.add(const Duration(seconds: 300)));
      expect(TokenRefresher.decodeJwtClaims(token)?['sub'], 'u1');
    });

    test('handles payloads that need base64 padding', () {
      // Different claim lengths exercise every padding case.
      for (final name in ['a', 'ab', 'abc', 'abcd']) {
        final token = makeJwt({'name': name, 'exp': 1});
        expect(TokenRefresher.decodeJwtClaims(token)?['name'], name);
      }
    });

    test('returns null for opaque or malformed tokens', () {
      expect(TokenRefresher.jwtExpiry('opaque-token'), isNull);
      expect(TokenRefresher.jwtExpiry('a.b'), isNull);
      expect(TokenRefresher.jwtExpiry('a.!!!.c'), isNull);
      expect(TokenRefresher.decodeJwtClaims('h.${base64Url.encode(utf8.encode('[1]'))}.s'), isNull);
      expect(TokenRefresher.jwtExpiry(makeJwt({'sub': 'no-exp'})), isNull);
    });
  });

  group('ensureFreshAccessToken', () {
    late MemoryTokenStorage tokens;
    late int calls;
    late TokenRefresher refresher;

    setUp(() {
      tokens = MemoryTokenStorage(refresh: 'r1');
      calls = 0;
      refresher = TokenRefresher(
        tokens: tokens,
        clock: () => now,
        refresh: (rt) async {
          calls++;
          return pair(makeJwt({'exp': secondsFromNow(900)}), 'r2');
        },
      );
    });

    test('returns the stored token when it is far from expiry', () async {
      tokens.access = makeJwt({'exp': secondsFromNow(600)});
      expect(await refresher.ensureFreshAccessToken(), tokens.access);
      expect(calls, 0);
    });

    test('refreshes when exp is within 60 s', () async {
      final stale = makeJwt({'exp': secondsFromNow(45)});
      tokens.access = stale;
      final fresh = await refresher.ensureFreshAccessToken();
      expect(calls, 1);
      expect(fresh, isNot(stale));
      expect(tokens.access, fresh);
      expect(tokens.refresh, 'r2', reason: 'rotated refresh token is stored');
    });

    test('refreshes when the token has already expired', () async {
      tokens.access = makeJwt({'exp': secondsFromNow(-10)});
      await refresher.ensureFreshAccessToken();
      expect(calls, 1);
    });

    test('returns an opaque token untouched', () async {
      tokens.access = 'opaque';
      expect(await refresher.ensureFreshAccessToken(), 'opaque');
      expect(calls, 0);
    });

    test('returns null when signed out', () async {
      tokens.access = null;
      expect(await refresher.ensureFreshAccessToken(), isNull);
      expect(calls, 0);
    });
  });

  group('refresh', () {
    test('is single-flight: concurrent callers share one network call', () async {
      final tokens = MemoryTokenStorage(access: 'old', refresh: 'r1');
      var calls = 0;
      final gate = Completer<TokenPair>();
      final refresher = TokenRefresher(
        tokens: tokens,
        refresh: (rt) {
          calls++;
          expect(rt, 'r1');
          return gate.future;
        },
      );

      final results = Future.wait([refresher.refresh(), refresher.refresh(), refresher.refresh()]);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(refresher.refreshing, isTrue);

      gate.complete(pair('new', 'r2'));
      expect(await results, ['new', 'new', 'new']);
      expect(refresher.refreshing, isFalse);
      expect(tokens.access, 'new');
      expect(tokens.refresh, 'r2');
      expect(tokens.writes, 1);

      // Once settled, the next call is a fresh refresh.
      await refresher.refresh();
      expect(calls, 2);
    });

    test('a rejected refresh clears tokens and reports sign-out', () async {
      final tokens = MemoryTokenStorage(access: 'old', refresh: 'revoked');
      final refresher = TokenRefresher(
        tokens: tokens,
        refresh: (_) async =>
            throw ApiException(code: 'unauthorized', message: 'revoked', statusCode: 401),
      );
      final signedOut = refresher.onSignedOut.first;

      expect(await refresher.refresh(), isNull);
      expect(tokens.access, isNull);
      expect(tokens.refresh, isNull);
      expect(tokens.clears, 1);
      await signedOut.timeout(const Duration(seconds: 1));
    });

    test('a transient failure keeps tokens for a later retry', () async {
      final tokens = MemoryTokenStorage(access: 'old', refresh: 'r1');
      var signedOut = false;
      final refresher = TokenRefresher(
        tokens: tokens,
        refresh: (_) async => throw ApiException(code: 'network_error', message: 'offline'),
      );
      refresher.onSignedOut.listen((_) => signedOut = true);

      expect(await refresher.refresh(), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(tokens.access, 'old');
      expect(tokens.refresh, 'r1');
      expect(signedOut, isFalse);

      final rateLimited = TokenRefresher(
        tokens: tokens,
        refresh: (_) async =>
            throw ApiException(code: 'rate_limited', message: 'slow down', statusCode: 429),
      );
      expect(await rateLimited.refresh(), isNull);
      expect(tokens.refresh, 'r1', reason: '429 is not a rejection of the token');

      final serverError = TokenRefresher(
        tokens: tokens,
        refresh: (_) async => throw StateError('boom'),
      );
      expect(await serverError.refresh(), isNull);
      expect(tokens.refresh, 'r1');
    });

    test('returns null without calling the network when there is no refresh token', () async {
      var calls = 0;
      final refresher = TokenRefresher(
        tokens: MemoryTokenStorage(),
        refresh: (_) async {
          calls++;
          return pair('x', 'y');
        },
      );
      expect(await refresher.refresh(), isNull);
      expect(calls, 0);
    });
  });
}
