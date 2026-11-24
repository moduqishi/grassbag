import 'dart:io';
import 'dart:typed_data';

Future<String?> writeTempQrImageFile(Uint8List bytes, String fileName) async {
  try {
    final ext = fileName.contains('.') ? fileName.split('.').last : 'png';
    final safeExt = ext.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final file = File(
      '${Directory.systemTemp.path}/grassbag_qr_${DateTime.now().microsecondsSinceEpoch}.${safeExt.isEmpty ? 'png' : safeExt}',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

Future<void> deleteTempQrImageFile(String? path) async {
  if (path == null || path.isEmpty) return;
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
