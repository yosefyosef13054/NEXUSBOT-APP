import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// What the About section shows: the build's version and number.
class AppInfo {
  const AppInfo({
    required this.version,
    required this.buildNumber,
    this.appName = 'NexusBot',
    this.packageName = '',
  });

  /// Mirrors `pubspec.yaml`'s `version:` (bump both together); used where
  /// `package_info_plus` has no implementation and as a compile-time constant.
  static const fallbackVersion = '1.4.0';
  static const fallbackBuildNumber = '5';
  static const fallback = AppInfo(version: fallbackVersion, buildNumber: fallbackBuildNumber);

  final String version;
  final String buildNumber;
  final String appName;
  final String packageName;

  /// `1.4.0 (5)`.
  String get versionLabel => buildNumber.isEmpty ? version : '$version ($buildNumber)';
}

/// Behind an interface so screens can be tested without the plugin.
abstract class AppInfoService {
  Future<AppInfo> load();
}

class PackageInfoAppInfoService implements AppInfoService {
  const PackageInfoAppInfoService();

  @override
  Future<AppInfo> load() async {
    final info = await PackageInfo.fromPlatform();
    return AppInfo(
      version: info.version.isEmpty ? AppInfo.fallback.version : info.version,
      buildNumber: info.buildNumber,
      appName: info.appName.isEmpty ? AppInfo.fallback.appName : info.appName,
      packageName: info.packageName,
    );
  }
}

/// Fixed answer (tests).
class StaticAppInfoService implements AppInfoService {
  const StaticAppInfoService(this.info);
  final AppInfo info;

  @override
  Future<AppInfo> load() async => info;
}

final appInfoServiceProvider = Provider<AppInfoService>((_) => const PackageInfoAppInfoService());

/// Resolves to [AppInfo.fallback] when the platform cannot answer, so the
/// About section always renders something.
final appInfoProvider = FutureProvider<AppInfo>((ref) async {
  try {
    return await ref.watch(appInfoServiceProvider).load();
  } catch (_) {
    return AppInfo.fallback;
  }
});
