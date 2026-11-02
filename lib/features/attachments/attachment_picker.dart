import 'dart:io' show File;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'attachment_widgets.dart' show AttachmentSource;

/// A file chosen by the user, read into memory for the multipart upload.
class PickedAttachment {
  const PickedAttachment({required this.bytes, required this.filename});
  final Uint8List bytes;
  final String filename;
}

/// Opens the platform pickers behind an interface so the chat screen can be
/// exercised without a device.
abstract class AttachmentPicker {
  /// Returns null when the user cancelled.
  Future<PickedAttachment?> pick(AttachmentSource source);
}

/// `image_picker` for the gallery / camera, `file_picker` for documents and
/// audio clips (the server accepts pdf, docx, md, txt, html, csv, json, log
/// and wav / mp3 / m4a / ogg / flac / webm).
class PlatformAttachmentPicker implements AttachmentPicker {
  PlatformAttachmentPicker({ImagePicker? imagePicker}) : _images = imagePicker ?? ImagePicker();

  final ImagePicker _images;

  static const documentExtensions = [
    'pdf',
    'docx',
    'md',
    'txt',
    'html',
    'csv',
    'json',
    'log',
    'wav',
    'mp3',
    'm4a',
    'ogg',
    'flac',
    'webm',
  ];

  @override
  Future<PickedAttachment?> pick(AttachmentSource source) async {
    switch (source) {
      case AttachmentSource.gallery:
      case AttachmentSource.camera:
        final file = await _images.pickImage(
          source: source == AttachmentSource.camera ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 2048,
          maxHeight: 2048,
          imageQuality: 90,
        );
        if (file == null) return null;
        return PickedAttachment(bytes: await file.readAsBytes(), filename: file.name);
      case AttachmentSource.file:
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: documentExtensions,
          withData: true,
        );
        final picked = result?.files.firstOrNull;
        if (picked == null) return null;
        var bytes = picked.bytes;
        if (bytes == null && picked.path != null) {
          bytes = await File(picked.path!).readAsBytes();
        }
        if (bytes == null) return null;
        return PickedAttachment(bytes: bytes, filename: picked.name);
    }
  }
}

final attachmentPickerProvider = Provider<AttachmentPicker>((_) => PlatformAttachmentPicker());
