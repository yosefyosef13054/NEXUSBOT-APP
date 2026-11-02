import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/paging.dart';

/// One row of `GET /admin/feedback`: a thumbs up / down a user left on an
/// assistant message.
class FeedbackEntry {
  const FeedbackEntry({
    required this.messageId,
    required this.sessionId,
    required this.userId,
    required this.rating,
    this.comment,
    this.createdAt,
  });

  factory FeedbackEntry.fromJson(Map<String, dynamic> j) => FeedbackEntry(
        messageId: (j['message_id'] as String?) ?? '',
        sessionId: (j['session_id'] as String?) ?? '',
        userId: (j['user_id'] as String?) ?? '',
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        comment: j['comment'] as String?,
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
      );

  final String messageId;
  final String sessionId;
  final String userId;

  /// `1` (thumbs up) or `-1` (thumbs down).
  final int rating;
  final String? comment;
  final DateTime? createdAt;

  bool get isPositive => rating > 0;
}

/// Server-administrator endpoints (`UserRead.role == "admin"`).
class AdminRepository {
  AdminRepository(this._client);
  final ApiClient _client;

  /// `GET /admin/feedback?page=&page_size=`.
  Future<PageResult<FeedbackEntry>> listFeedback({int page = 1, int pageSize = 50}) async {
    final res = await _client.request<Map<String, dynamic>>(
      '/admin/feedback',
      query: {'page': page, 'page_size': pageSize},
    );
    return PageResult.fromJson(res.data ?? const {}, FeedbackEntry.fromJson);
  }
}

final adminRepositoryProvider = FutureProvider<AdminRepository>((ref) async {
  final client = await ref.watch(apiClientProvider.future);
  return AdminRepository(client);
});
