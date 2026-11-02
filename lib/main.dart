import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'core/env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF050505),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  const app = ProviderScope(child: NexusBotApp());
  if (!Env.sentryEnabled) {
    runApp(app);
    return;
  }
  // Crash reporting only when a DSN was compiled in
  // (`--dart-define=SENTRY_DSN=…`); no personal data is attached.
  await SentryFlutter.init(
    (options) {
      options
        ..dsn = Env.sentryDsn
        ..environment = Env.sentryEnvironment
        ..sendDefaultPii = false
        ..tracesSampleRate = 0.1;
    },
    appRunner: () => runApp(SentryWidget(child: app)),
  );
}
