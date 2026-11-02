import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_providers.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/collections/collections_screen.dart';
import '../features/documents/documents_screen.dart';
import '../features/settings/settings_screen.dart';
import '../shared/home_shell.dart';

/// Route locations. Everything under the shell keeps the sidebar mounted.
class AppRoutes {
  const AppRoutes._();
  static const splash = '/splash';
  static const login = '/login';
  static const register = '/register';
  static const home = '/';
  static const documents = '/documents';
  static const collections = '/collections';
  static const settings = '/settings';
  static String chat(String sessionId) => '/chat/$sessionId';
}

final routerProvider = Provider<GoRouter>((ref) {
  // Force-refresh the router whenever auth state flips.
  final auth = ref.watch(currentUserProvider);

  return GoRouter(
    initialLocation: AppRoutes.splash,
    debugLogDiagnostics: false,
    refreshListenable: _ProviderRefresh(ref),
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final isAuthRoute = loc == AppRoutes.login || loc == AppRoutes.register;
      if (loc == AppRoutes.splash) {
        return auth.when(
          loading: () => null,
          error: (_, __) => AppRoutes.login,
          data: (u) => u == null ? AppRoutes.login : AppRoutes.home,
        );
      }
      // While auth is loading anywhere else (e.g. a browser refresh on
      // /chat/<id>), leave the route as-is so the deep link survives.
      if (auth.isLoading) return null;
      final loggedIn = auth.valueOrNull != null;
      if (!loggedIn && !isAuthRoute) return AppRoutes.login;
      if (loggedIn && isAuthRoute) return AppRoutes.home;
      return null;
    },
    routes: [
      GoRoute(path: AppRoutes.splash, builder: (_, __) => const SplashScreen()),
      GoRoute(path: AppRoutes.login, builder: (_, __) => const LoginScreen()),
      GoRoute(path: AppRoutes.register, builder: (_, __) => const RegisterScreen()),
      ShellRoute(
        builder: (context, state, child) => HomeShell(
          location: state.uri.path,
          selectedSessionId: state.pathParameters['sessionId'],
          child: child,
        ),
        routes: [
          GoRoute(
            path: AppRoutes.home,
            pageBuilder: (_, state) => _fadePage(state.pageKey, const HomeLanding()),
          ),
          GoRoute(
            path: '/chat/:sessionId',
            pageBuilder: (_, state) {
              final id = state.pathParameters['sessionId']!;
              return _fadePage(
                ValueKey('chat-$id'),
                ChatScreen(key: ValueKey(id), sessionId: id),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.documents,
            pageBuilder: (_, state) => _fadePage(state.pageKey, const DocumentsScreen()),
          ),
          GoRoute(
            path: AppRoutes.collections,
            pageBuilder: (_, state) => _fadePage(state.pageKey, const CollectionsScreen()),
          ),
          GoRoute(
            path: AppRoutes.settings,
            pageBuilder: (_, state) => _fadePage(state.pageKey, const SettingsScreen()),
          ),
        ],
      ),
    ],
  );
});

/// Subtle fade + lift between shell children (the sidebar stays put).
CustomTransitionPage<void> _fadePage(LocalKey key, Widget child) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    transitionsBuilder: (_, animation, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(animation),
        child: child,
      ),
    ),
  );
}

/// Bridges Riverpod state changes to GoRouter's Listenable-based refresh.
class _ProviderRefresh extends ChangeNotifier {
  _ProviderRefresh(Ref ref) {
    ref.listen(currentUserProvider, (_, __) => notifyListeners());
  }
}
