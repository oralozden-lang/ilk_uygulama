import 'dart:io';
import 'package:path_provider/path_provider.dart';

Future<void> excelKaydet(List<int> bytes, String dosyaAdi) async {
  Directory? dir;
  try {
    if (Platform.isAndroid) {
      dir = Directory('/storage/emulated/0/Download');
      if (!await dir.exists()) {
        dir = await getExternalStorageDirectory();
      }
    } else {
      // iOS
      dir = await getApplicationDocumentsDirectory();
    }
  } catch (_) {
    dir = await getApplicationDocumentsDirectory();
  }
  final dosya = File('${dir!.path}/$dosyaAdi');
  await dosya.writeAsBytes(bytes);
}
