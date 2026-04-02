// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

Future<void> excelKaydet(List<int> bytes, String dosyaAdi) async {
  final blob = html.Blob(
    [bytes],
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', dosyaAdi)
    ..click();
  html.Url.revokeObjectUrl(url);
}
