import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth_models.dart';
import 'api_exception.dart';
import 'auth_session.dart';
import 'env.dart';
import 'secure_storage.dart';
import 'sse_parser.dart';

export 'api_exception.dart';

/// Authenticated API client.
///
/// - Injects `Authorization: Bearer <jwt>` on every request from secure storage.
/// - On 401, refreshes the access token through the single-flight
///   [TokenRefresher] (concurrent 401s await the same refresh), retries the
///   original request once, and only fails if the refresh itself fails.
/// - Maps every non-2xx response and transport failure to [ApiException]
///   (carrying the envelope's `request_id`), so screens never see `dio` types.
/// - Opens SSE streams through the same Dio instance ([openEventStream]) so
///   the auth interceptor applies to streaming too.
/// - Adds `X-Org-Id: <active org>` to every request when [activeOrgId]
///   returns one (absent = the user's personal workspace).
class ApiClient {
  ApiClient({required this.dio, required this.tokens, required this.refresher});

  final Dio dio;
  final TokenStorage tokens;
  final TokenRefresher refresher;

  /// Header that selects the organization a request acts in.
  static const orgHeader = 'X-Org-Id';

  /// Resolves the active organization for the next request; installed by the
  /// auth layer once the signed-in user is known (see `currentUserProvider`)
  /// so one device shared by two accounts never sends the other's org.
  /// Null / empty = no header = the personal workspace.
  String? Function()? activeOrgId;

  /// The organization id the next request would carry, if any.
  String? get currentOrgId {
    final id = activeOrgId?.call();
    return id == null || id.isEmpty ? null : id;
  }

  static ApiClient create(TokenStorage tokens, {String baseUrl = Env.apiBaseUrl}) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 30),
        headers: {'Content-Type': 'application/json'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final refresher = TokenRefresher(
      tokens: tokens,
      refresh: (refreshToken) => _refreshCall(baseUrl, refreshToken),
    );
    final client = ApiClient(dio: dio, tokens: tokens, refresher: refresher);
    dio.interceptors.add(_AuthInterceptor(client));
    return client;
  }

  /// `POST /auth/refresh` on a bare Dio — no interceptors, so a failing
  /// refresh can never recurse into another refresh.
  static Future<TokenPair> _refreshCall(String baseUrl, String refreshToken) async {
    final bare = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    try {
      final res = await bare.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      return TokenPair.fromJson(res.data!);
    } on DioException catch (e) {
      throw e.toApiException();
    }
  }

  /// Proactively refreshes the access token if it expires within a minute.
  /// Call before opening a long-lived stream.
  Future<String?> ensureFreshAccessToken() => refresher.ensureFreshAccessToken();

  /// Performs a request and converts any failure — transport error or
  /// non-2xx envelope — into [ApiException].
  ///
  /// [authRetry] disables the transparent 401-refresh-retry for endpoints
  /// where a 401 means "wrong credentials" rather than "stale token"
  /// (login, password confirmation, …).
  Future<Response<T>> request<T>(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    Options? options,
    bool authRetry = true,
    ProgressCallback? onSendProgress,
  }) async {
    final base = options ?? Options();
    final opts = base.copyWith(
      method: method,
      extra: {
        ...?base.extra,
        if (!authRetry) _AuthInterceptor.skipRefreshKey: true,
      },
    );
    final Response<T> res;
    try {
      res = await dio.request<T>(
        path,
        data: data,
        queryParameters: query,
        options: opts,
        onSendProgress: onSendProgress,
      );
    } on DioException catch (e) {
      throw e.toApiException();
    }
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      final requestId = res.headers.value('x-request-id');
      throw ApiException.fromEnvelope(
            res.data,
            statusCode: status,
            headerRequestId: requestId,
          ) ??
          ApiException(
            code: 'http_$status',
            message: 'Request failed ($status)',
            statusCode: status,
            requestId: requestId,
          );
    }
    return res;
  }

  /// Opens a `text/event-stream` request through [dio] — so the auth
  /// interceptor and token refresh apply — and returns the parsed frames.
  ///
  /// Cancelling the subscription on the returned stream closes the underlying
  /// HTTP connection, so the server sees the disconnect. (Dio's response
  /// stream only releases its socket when the request's [CancelToken] is
  /// cancelled — a plain subscription cancel is swallowed by its internal
  /// controller — so the stream owns a token and cancels it on `onCancel`.)
  ///
  /// Throws [ApiException] when the server answers with a non-2xx envelope;
  /// transport failures mid-stream arrive as [ApiException] errors on the
  /// stream.
  /// [headers] are added to the request (e.g. `Idempotency-Key`,
  /// `Last-Event-ID`); [query] becomes the query string.
  Future<Stream<SseEvent>> openEventStream(
    String path, {
    String method = 'POST',
    Object? data,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    await ensureFreshAccessToken();
    final token = cancelToken ?? CancelToken();
    final Response<ResponseBody> res;
    try {
      res = await dio.request<ResponseBody>(
        path,
        data: data,
        queryParameters: query,
        cancelToken: token,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          // Dio applies receiveTimeout *between chunks* on a stream; a slow
          // tool call or a long think must not kill the turn.
          receiveTimeout: streamIdleTimeout,
          headers: {
            'Accept': 'text/event-stream',
            'Cache-Control': 'no-cache',
            ...?headers,
          },
        ),
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      if (body is ResponseBody) {
        throw await _exceptionFromStreamBody(body, e.response?.statusCode ?? 0);
      }
      throw e.toApiException();
    }
    final body = res.data;
    final status = res.statusCode ?? 0;
    if (body == null) {
      throw ApiException(code: 'network_error', message: 'Empty response', statusCode: status);
    }
    if (status < 200 || status >= 300) {
      throw await _exceptionFromStreamBody(body, status);
    }

    final frames = const SseTransformer().bind(utf8.decoder.bind(body.stream));
    final out = StreamController<SseEvent>();
    StreamSubscription<SseEvent>? inner;
    out.onListen = () {
      inner = frames.listen(
        out.add,
        onError: (Object e, StackTrace st) =>
            out.addError(e is DioException ? e.toApiException() : e, st),
        onDone: out.close,
      );
    };
    out.onPause = () => inner?.pause();
    out.onResume = () => inner?.resume();
    out.onCancel = () async {
      if (!token.isCancelled) token.cancel('closed by client');
      await inner?.cancel();
    };
    return out.stream;
  }

  /// Longest gap between two SSE frames before the stream is considered dead.
  static const streamIdleTimeout = Duration(minutes: 5);

  /// Reads a (small) error body from a streaming response and maps it.
  static Future<ApiException> _exceptionFromStreamBody(ResponseBody body, int status) async {
    var text = '';
    try {
      text = await utf8.decodeStream(body.stream);
    } catch (_) {
      // Body unreadable; fall through to a status-only exception.
    }
    Object? json;
    if (text.isNotEmpty) {
      try {
        json = jsonDecode(text);
      } on FormatException {
        json = null;
      }
    }
    final requestId = body.headers['x-request-id']?.firstOrNull;
    return ApiException.fromEnvelope(json, statusCode: status, headerRequestId: requestId) ??
        ApiException(
          code: 'http_$status',
          message: text.isEmpty ? 'Request failed ($status)' : text,
          statusCode: status,
          requestId: requestId,
        );
  }
}

/// Adds the bearer token to every request and recovers from 401s.
///
/// A 401 triggers one refresh through [TokenRefresher] (single-flight, so a
/// burst of 401s from parallel requests shares a single refresh call) and one
/// retry. If another request already rotated the tokens in the meantime, the
/// retry simply reuses the new access token without refreshing again.
class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this.client);
  final ApiClient client;

  /// `RequestOptions.extra` flag: never attempt a refresh-and-retry.
  static const skipRefreshKey = 'nexusbot.skipAuthRefresh';
  static const _retriedKey = 'nexusbot.authRetried';

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (options.headers['Authorization'] == null) {
      final access = await client.tokens.readAccess();
      if (access != null) {
        options.headers['Authorization'] = 'Bearer $access';
      }
    }
    // Resources belong to the active organization; the header is resolved per
    // request so switching workspaces needs no new client.
    final orgId = client.currentOrgId;
    if (orgId != null && options.headers[ApiClient.orgHeader] == null) {
      options.headers[ApiClient.orgHeader] = orgId;
    }
    handler.next(options);
  }

  @override
  Future<void> onResponse(Response response, ResponseInterceptorHandler handler) async {
    // 401s arrive here (not in onError) because validateStatus accepts < 500.
    if (response.statusCode == 401) {
      try {
        final retried = await _retryWithFreshToken(response.requestOptions);
        if (retried != null) {
          _discardBody(response);
          return handler.resolve(retried);
        }
      } on DioException catch (e) {
        return handler.reject(e);
      }
    }
    handler.next(response);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 401) {
      try {
        final retried = await _retryWithFreshToken(err.requestOptions);
        if (retried != null) return handler.resolve(retried);
      } on DioException catch (e) {
        return handler.next(e);
      }
    }
    handler.next(err);
  }

  Future<Response<dynamic>?> _retryWithFreshToken(RequestOptions original) async {
    if (original.extra[skipRefreshKey] == true) return null;
    if (original.extra[_retriedKey] == true) return null;
    if (original.path.contains('/auth/refresh')) return null;
    // A request that carried no token is not something a refresh can fix.
    final used = original.headers['Authorization'] as String?;
    if (used == null) return null;

    final current = await client.tokens.readAccess();
    final String? access;
    if (current != null && 'Bearer $current' != used) {
      // Someone already rotated the pair while this request was in flight.
      access = current;
    } else {
      access = await client.refresher.refresh();
    }
    if (access == null) return null;

    original.headers['Authorization'] = 'Bearer $access';
    original.extra[_retriedKey] = true;
    return client.dio.fetch<dynamic>(original);
  }

  /// A superseded streaming 401 response still holds a socket; let it drain.
  static void _discardBody(Response<dynamic> response) {
    final data = response.data;
    if (data is ResponseBody) {
      unawaited(data.stream.drain<void>().then((_) {}, onError: (_) {}));
    }
  }
}

extension _DioExceptionX on DioException {
  ApiException toApiException() {
    final res = response;
    final requestId = res?.headers.value('x-request-id');
    final fromEnvelope = ApiException.fromEnvelope(
      res?.data,
      statusCode: res?.statusCode,
      headerRequestId: requestId,
    );
    if (fromEnvelope != null) return fromEnvelope;
    final code = switch (type) {
      DioExceptionType.cancel => 'cancelled',
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        'timeout',
      DioExceptionType.badResponse => 'http_${res?.statusCode}',
      _ => 'network_error',
    };
    return ApiException(
      code: code,
      message: message ?? 'Network error',
      statusCode: res?.statusCode,
      requestId: requestId,
    );
  }
}

final apiClientProvider = FutureProvider<ApiClient>((ref) async {
  final tokens = ref.watch(tokenStorageProvider);
  return ApiClient.create(tokens);
});
