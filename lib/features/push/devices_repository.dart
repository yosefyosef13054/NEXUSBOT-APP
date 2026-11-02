import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';

/// One registered push token (`GET /devices` item) — only the token's last
/// characters come back.
class Device {
  const Device({
    required this.id,
    required this.platform,
    required this.tokenSuffix,
    this.appVersion,
    this.locale,
    this.lastSeenAt,
    this.createdAt,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: (j['id'] as String?) ?? '',
        platform: (j['platform'] as String?) ?? '',
        tokenSuffix: (j['token_suffix'] as String?) ?? '',
        appVersion: j['app_version'] as String?,
        locale: j['locale'] as String?,
        lastSeenAt: DateTime.tryParse(j['last_seen_at'] as String? ?? ''),
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
      );

  final String id;
  final String platform;
  final String tokenSuffix;
  final String? appVersion;
  final String? locale;
  final DateTime? lastSeenAt;
  final DateTime? createdAt;
}

class DeviceList {
  const DeviceList({required this.items, required this.pushEnabled});

  factory DeviceList.fromJson(Map<String, dynamic> j) => DeviceList(
        items: (j['items'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => Device.fromJson(m.cast<String, dynamic>()))
            .toList(),
        pushEnabled: j['push_enabled'] == true,
      );

  final List<Device> items;

  /// The server has a delivery provider configured (`PUSH_PROVIDER`).
  final bool pushEnabled;
}

/// `/devices` — push token registration.
class DevicesRepository {
  DevicesRepository(this._client);
  final ApiClient _client;

  /// `POST /devices` → 201 (idempotent upsert per platform + token).
  Future<Device> register({
    required String platform,
    required String token,
    String? appVersion,
    String? locale,
  }) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/devices',
      method: 'POST',
      data: {
        'platform': platform,
        'token': token,
        if (appVersion != null) 'app_version': appVersion,
        if (locale != null) 'locale': locale,
      },
    );
    return Device.fromJson(res.data ?? const {});
  }

  Future<DeviceList> list() async {
    final res = await _client.request<Map<String, dynamic>>('/devices');
    return DeviceList.fromJson(res.data ?? const {});
  }

  /// `DELETE /devices/{token}` — 404 when the token was never registered.
  Future<void> unregister(String token) async {
    await _client.request<dynamic>('/devices/${Uri.encodeComponent(token)}', method: 'DELETE');
  }
}

final devicesRepositoryProvider = FutureProvider<DevicesRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return DevicesRepository(client);
});
