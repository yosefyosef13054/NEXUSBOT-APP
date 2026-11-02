import 'dart:async';
import 'dart:convert';

import '../features/auth/auth_models.dart';
import 'api_exception.dart';
import 'secure_storage.dart';

/// The network call that exchanges a refresh token for a new [TokenPair].
/// Throws [ApiException] when the server rejects it.
typedef RefreshTokenCall = Future<TokenPair> Function(String refreshToken);

/// Refresh-token logic shared by the HTTP interceptor and the streaming
/// transports (SSE / WebSocket).
///
/// - **Single-flight:** however many callers hit [refresh] while a refresh is
///   in flight, exactly one `/auth/refresh` call is made and every caller
///   receives its result. Refresh tokens rotate server-side, so a second
///   concurrent call would be rejected as a reuse.
/// - **Proactive:** [ensureFreshAccessToken] decodes the JWT `exp` claim and
///   refreshes when the token expires within [leeway], so long-lived streams
///   are opened with a token that will not die mid-stream.
/// - **Definitive rejections** (401 / other 4xx except rate limiting) clear
///   the stored tokens and emit on [onSignedOut] so the app can bounce to
///   `/login`. Transient failures (network, 5xx) keep the tokens.
class TokenRefresher {
  TokenRefresher({
    required TokenStorage tokens,
    required RefreshTokenCall refresh,
    DateTime Function()? clock,
    this.leeway = const Duration(seconds: 60),
  })  : _tokens = tokens,
        _refresh = refresh,
        _clock = clock ?? DateTime.now;

  final TokenStorage _tokens;
  final RefreshTokenCall _refresh;
  final DateTime Function() _clock;

  /// Tokens expiring within this window are refreshed proactively.
  final Duration leeway;

  Future<String?>? _inFlight;
  final _signedOut = StreamController<void>.broadcast();

  /// Fires when a refresh was definitively rejected and local tokens were
  /// cleared — the user must sign in again.
  Stream<void> get onSignedOut => _signedOut.stream;

  /// Whether a refresh is currently in flight.
  bool get refreshing => _inFlight != null;

  /// Exchanges the stored refresh token for a new pair and stores it.
  ///
  /// Returns the new access token, or `null` when there is no refresh token
  /// or the refresh failed. Concurrent callers share one in-flight request.
  Future<String?> refresh() {
    return _inFlight ??= _doRefresh().whenComplete(() => _inFlight = null);
  }

  Future<String?> _doRefresh() async {
    final refreshToken = await _tokens.readRefresh();
    if (refreshToken == null) return null;

    final TokenPair pair;
    try {
      pair = await _refresh(refreshToken);
    } on ApiException catch (e) {
      if (_isDefinitiveRejection(e)) await _signOut();
      return null;
    } catch (_) {
      // Transport failure: keep the tokens, the next request will retry.
      return null;
    }

    await _tokens.writeTokens(access: pair.accessToken, refresh: pair.refreshToken);
    return pair.accessToken;
  }

  /// Returns an access token that is good for at least [leeway], refreshing
  /// first when needed. Returns `null` when signed out. Opaque (non-JWT)
  /// tokens are returned as-is and left for the server to judge.
  Future<String?> ensureFreshAccessToken() async {
    final access = await _tokens.readAccess();
    if (access == null) return null;
    final expiry = jwtExpiry(access);
    if (expiry == null) return access;
    if (expiry.difference(_clock()) <= leeway) {
      return await refresh() ?? await _tokens.readAccess();
    }
    return access;
  }

  Future<void> _signOut() async {
    await _tokens.clear();
    if (!_signedOut.isClosed) _signedOut.add(null);
  }

  static bool _isDefinitiveRejection(ApiException e) {
    if (e.isAuth) return true;
    final status = e.statusCode;
    return status != null && status >= 400 && status < 500 && !e.isRateLimited;
  }

  /// Decodes the payload of a JWT (base64url, no padding) without verifying
  /// it. Returns `null` for anything that is not a well-formed JWT.
  static Map<String, dynamic>? decodeJwtClaims(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final json = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(json);
      return claims is Map<String, dynamic> ? claims : null;
    } on FormatException {
      return null;
    }
  }

  /// The `exp` claim of [token] as a UTC [DateTime], or `null` when absent.
  static DateTime? jwtExpiry(String token) {
    final exp = decodeJwtClaims(token)?['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(), isUtc: true);
  }
}
