import 'package:flutter_test/flutter_test.dart';
import 'package:nexusbot/features/share_intake/share_intake.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  test('IncomingShare.fromMedia joins text and URLs and keeps files', () {
    final share = IncomingShare.fromMedia([
      SharedMediaFile(path: 'Look at this', type: SharedMediaType.text),
      SharedMediaFile(path: 'https://example.com/a', type: SharedMediaType.url),
      SharedMediaFile(
        path: '/tmp/cache/photo.jpg?x=1',
        type: SharedMediaType.image,
        mimeType: 'image/jpeg',
      ),
      SharedMediaFile(path: 'C:\\tmp\\notes.pdf', type: SharedMediaType.file, message: 'memo'),
    ]);
    expect(share.text, 'Look at this\nhttps://example.com/a\nmemo');
    expect(share.files.map((f) => f.name), ['photo.jpg', 'notes.pdf']);
    expect(share.files.first.mimeType, 'image/jpeg');
    expect(share.isEmpty, isFalse);
    expect(IncomingShare.fromMedia(const []).isEmpty, isTrue);
    expect(const IncomingShare(text: '   ').isEmpty, isTrue);
  });

  test('the router parks the share and opens the intake screen', () {
    final visited = <String>[];
    IncomingShare? parked;
    final router = ShareIntakeRouter(navigate: visited.add, park: (s) => parked = s);
    expect(router.handle(const IncomingShare()), isFalse);
    expect(visited, isEmpty);

    const share = IncomingShare(text: 'hello');
    expect(router.handle(share), isTrue);
    expect(parked, same(share));
    expect(visited, ['/share']);
  });

  test('NoopIncomingShareService never delivers anything', () async {
    const service = NoopIncomingShareService();
    expect(await service.initialShare(), isNull);
    expect(await service.shares.isEmpty, isTrue);
  });
}
