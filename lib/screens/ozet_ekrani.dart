import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:excel/excel.dart' as xl;
import '../excel_download.dart';
import 'on_hazirlik_ekrani.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/utils.dart';

class OzetEkrani extends StatefulWidget {
  final String subeKodu;
  final DateTime baslangicTarihi;
  final List<String> subeler;
  final int gecmisGunHakki;

  const OzetEkrani({
    super.key,
    required this.subeKodu,
    required this.baslangicTarihi,
    this.subeler = const [],
    this.gecmisGunHakki = 0,
  });

  @override
  State<OzetEkrani> createState() => _OzetEkraniState();
}

class _OzetEkraniState extends State<OzetEkrani> {
  late DateTime _secilenTarih;
  late String _secilenSube;
  Map<String, dynamic>? _kayit;
  bool _yukleniyor = true;
  Map<String, String> _subeAdlari = {};
  List<Map<String, dynamic>> _tutarsizTransferler = [];

  @override
  void initState() {
    super.initState();
    _secilenTarih = widget.baslangicTarihi;
    _secilenSube = widget.subeKodu;
    _subeAdlariniYukle();
    _kayitYukle();
  }

  Future<void> _subeAdlariniYukle() async {
    if (widget.subeler.isEmpty) return;
    try {
      final Map<String, String> adlar = {};
      for (var id in widget.subeler) {
        final doc = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(id)
            .get();
        adlar[id] = doc.data()?['ad'] as String? ?? id;
      }
      if (mounted) setState(() => _subeAdlari = adlar);
    } catch (_) {}
  }

  String _tarihKey(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  String _tarihGoster(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';

  // ── Pulse kanallarını parse et ─────────────────────────────────────────────
  // pulseKiyasVerileri: {'yemek_Metropol': '800', 'online_DominosOnl': '450', ...}
  Map<String, Map<String, double>> _pulseKanallariniAyir(
      Map<String, dynamic> d) {
    final pulseKiyas = d['pulseKiyasVerileri'] as Map? ?? {};
    final yemekler = <String, double>{};
    final onlineler = <String, double>{};

    for (final entry in pulseKiyas.entries) {
      final key = entry.key.toString();
      final val =
          double.tryParse(entry.value.toString().replaceAll(',', '.')) ?? 0;
      if (val <= 0) continue;
      if (key.startsWith('yemek_')) {
        final ad = key.substring(6); // 'yemek_Metropol' → 'Metropol'
        yemekler[ad] = val;
      } else if (key != 'pulsePos' &&
          key != 'pulseBrut' &&
          key != 'bankapara') {
        // online kanallar — pulsePos, pulseBrut, bankapara hariç
        // key olduğu gibi kullan — Firestore'daki sistem adı
        onlineler[key] = val;
      }
    }
    return {'yemek': yemekler, 'online': onlineler};
  }

  Future<void> _excelAralikSec() async {
    DateTime baslangic = DateTime.now().subtract(const Duration(days: 30));
    DateTime bitis = DateTime.now();

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Excel için Tarih Aralığı'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.calendar_today),
                title: const Text('Başlangıç'),
                subtitle: Text(_tarihGoster(baslangic)),
                onTap: () async {
                  final d = await showDatePicker(
                      context: ctx,
                      initialDate: baslangic,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now());
                  if (d != null) setS(() => baslangic = d);
                },
              ),
              ListTile(
                leading: const Icon(Icons.calendar_today),
                title: const Text('Bitiş'),
                subtitle: Text(_tarihGoster(bitis)),
                onTap: () async {
                  final d = await showDatePicker(
                      context: ctx,
                      initialDate: bitis,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now());
                  if (d != null) setS(() => bitis = d);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('İptal')),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _excelOlustur(baslangic, bitis);
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white),
              child: const Text('Excel Oluştur'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _excelOlustur(DateTime baslangic, DateTime bitis) async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Excel hazırlanıyor...'),
          duration: Duration(seconds: 2)));
    }

    try {
      final kayitlar = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(_secilenSube)
          .collection('gunluk')
          .orderBy('tarih')
          .get();

      final bas = _tarihKey(baslangic);
      final bit = _tarihKey(bitis);
      final filtreliKayitlar = kayitlar.docs
          .where((d) => d.id.compareTo(bas) >= 0 && d.id.compareTo(bit) <= 0)
          .toList();

      if (filtreliKayitlar.isEmpty) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Seçili tarih aralığında kayıt bulunamadı'),
              backgroundColor: Colors.orange));
        return;
      }

      final excel = xl.Excel.createExcel();
      excel.rename('Sheet1', 'Kasa Takip');
      final sheet = excel['Kasa Takip'];

      final List<Map<String, String>> kolonlar = [
        {'ad': 'Tarih', 'renk': '#0288D1'},
        {'ad': 'Devreden Flot', 'renk': '#2E7D32'},
        {'ad': 'Ekranda Görünen Nakit', 'renk': '#F57F17'},
        {'ad': 'Toplam POS', 'renk': '#0288D1'},
        {'ad': 'Günlük Satış Toplamı', 'renk': '#C62828'},
        {'ad': 'Toplam Harcama', 'renk': '#C62828'},
        {'ad': 'Günlük Flot', 'renk': '#2E7D32'},
        {'ad': 'Kasa Farkı', 'renk': '#6A1B9A'},
        {'ad': 'Ana Kasa Kalanı (TL)', 'renk': '#1565C0'},
        {'ad': 'Ana Kasa Kalanı (USD)', 'renk': '#E65100'},
        {'ad': 'Ana Kasa Kalanı (EUR)', 'renk': '#6A1B9A'},
        {'ad': 'Ana Kasa Kalanı (GBP)', 'renk': '#00695C'},
        {'ad': 'Ana Kasa Harcama', 'renk': '#BF360C'},
        {'ad': 'Nakit Çıkış', 'renk': '#7B1FA2'},
        {'ad': 'Bankaya Yatan (TL)', 'renk': '#1565C0'},
        {'ad': 'Bankaya Yatan (USD)', 'renk': '#E65100'},
        {'ad': 'Bankaya Yatan (EUR)', 'renk': '#6A1B9A'},
        {'ad': 'Bankaya Yatan (GBP)', 'renk': '#00695C'},
        {'ad': 'Transferler Toplam', 'renk': '#37474F'},
        {'ad': 'Diğer Alımlar Toplam', 'renk': '#37474F'},
      ];

      for (int i = 0; i < kolonlar.length; i++) {
        final cell = sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
        cell.value = xl.TextCellValue(kolonlar[i]['ad']!);
        cell.cellStyle = xl.CellStyle(
          bold: true,
          backgroundColorHex: xl.ExcelColor.fromHexString(kolonlar[i]['renk']!),
          fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        );
      }

      for (int r = 0; r < filtreliKayitlar.length; r++) {
        final d = filtreliKayitlar[r].data();
        final dovizKalanlar = d['dovizAnaKasaKalanlari'] as Map? ?? {};
        final bankaDovizler = (d['bankaDovizler'] as List?)?.cast<Map>() ?? [];
        double bankaUSD = 0, bankaEUR = 0, bankaGBP = 0;
        for (var bd in bankaDovizler) {
          final cins = bd['cins'] as String? ?? '';
          final miktar = (bd['miktar'] as num? ?? 0).toDouble();
          if (cins == 'USD') bankaUSD += miktar;
          if (cins == 'EUR') bankaEUR += miktar;
          if (cins == 'GBP') bankaGBP += miktar;
        }
        final transferler = (d['transferler'] as List?)?.cast<Map>() ?? [];
        double transferGiden = 0, transferGelen = 0;
        for (var t in transferler) {
          final kat = t['kategori'] as String? ?? '';
          final tutar = (t['tutar'] as num? ?? 0).toDouble();
          if (kat == 'GİDEN') transferGiden += tutar;
          if (kat == 'GELEN') transferGelen += tutar;
        }
        final transferNet = transferGelen - transferGiden;
        final digerAlimlar = (d['digerAlimlar'] as List?)?.cast<Map>() ?? [];
        final digerToplam = digerAlimlar.fold(
            0.0, (s, t) => s + (t['tutar'] as num? ?? 0).toDouble());
        final tarihRaw = d['tarih'] as String? ?? '';
        String tarihFormatli = d['tarihGoster'] ?? tarihRaw;
        if (tarihRaw.length == 10) {
          final tp = tarihRaw.split('-');
          if (tp.length == 3) tarihFormatli = '${tp[2]}.${tp[1]}.${tp[0]}';
        }

        final List<dynamic> satirVeriler = [
          tarihFormatli,
          _toDouble(d['devredenFlot']),
          _toDouble(d['ekrandaGorunenNakit']),
          _toDouble(d['toplamPos']),
          _toDouble(d['gunlukSatisToplami']),
          _toDouble(d['toplamHarcama']),
          _toDouble(d['gunlukFlot']),
          _toDouble(d['kasaFarki']),
          _toDouble(d['anaKasaKalani']),
          _toDouble(dovizKalanlar['USD']),
          _toDouble(dovizKalanlar['EUR']),
          _toDouble(dovizKalanlar['GBP']),
          _toDouble(d['toplamAnaKasaHarcama']),
          _toDouble(d['toplamNakitCikis']),
          _toDouble(d['bankayaYatirilan']),
          bankaUSD,
          bankaEUR,
          bankaGBP,
          transferNet,
          digerToplam,
        ];

        for (int c = 0; c < satirVeriler.length; c++) {
          final cell = sheet.cell(
              xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
          final val = satirVeriler[c];
          if (val is String) {
            cell.value = xl.TextCellValue(val);
          } else {
            final dVal = (val as double);
            if (dVal != 0) cell.value = xl.DoubleCellValue(dVal);
          }
        }
      }

      for (int i = 0; i < kolonlar.length; i++) {
        sheet.setColumnWidth(i, i == 0 ? 14 : 20);
      }

      final bytes = excel.encode();
      if (bytes == null) return;
      final subeAd = _subeAdlari[_secilenSube] ?? _secilenSube;
      final dosyaAdi =
          'Kasa_Takip_${subeAd}_${_tarihGoster(baslangic)}-${_tarihGoster(bitis)}.xlsx'
              .replaceAll('/', '-');
      await excelKaydet(bytes, dosyaAdi);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(kIsWeb
                ? 'Excel indiriliyor: $dosyaAdi'
                : 'Excel kaydedildi: $dosyaAdi'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4)));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _pdfOlustur(
    Map<String, dynamic> d, {
    double? aylikSatisToplami,
    List<Map<String, dynamic>> tutarsizTransferler = const [],
  }) async {
    final pdf = pw.Document();
    final subeAd = _subeAdlari[_secilenSube] ?? _secilenSube;
    final font = await PdfGoogleFonts.notoSansRegular();
    final fontBold = await PdfGoogleFonts.notoSansBold();

    String fmt(dynamic val) {
      if (val == null) return '0,00';
      final double v = (val as num).toDouble();
      final parts = v.toStringAsFixed(2).split('.');
      final intPart = parts[0];
      final decPart = parts[1];
      final buffer = StringBuffer();
      for (int i = 0; i < intPart.length; i++) {
        if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
        buffer.write(intPart[i]);
      }
      return '${buffer.toString()},$decPart';
    }

    final harcamalar = (d['harcamalar'] as List?)?.cast<Map>() ?? [];
    final anaHarcamalar = (d['anaKasaHarcamalari'] as List?)?.cast<Map>() ?? [];
    final transferListesi = (d['transferler'] as List?)
            ?.cast<Map>()
            .where((t) => t['kategori'] == 'GİDEN' || t['kategori'] == 'GELEN')
            .toList() ??
        [];
    final digerAlimlarListesi =
        ((d['digerAlimlar'] as List?)?.cast<Map>() ?? []).where((da) {
      final aciklama = (da['aciklama'] ?? '').toString().trim();
      final tutar = (da['tutar'] as num? ?? 0).toDouble();
      return aciklama.isNotEmpty || tutar > 0;
    }).toList();

    const dovizTurleri = ['USD', 'EUR', 'GBP'];
    const dovizSembolleri = {'USD': '\$', 'EUR': '€', 'GBP': '£'};
    final dovizler = (d['dovizler'] as List?)?.cast<Map>() ?? [];
    final dovizKalanlar = d['dovizAnaKasaKalanlari'] as Map?;
    final oncekiDovizKalanlar = d['oncekiDovizAnaKasaKalanlari'] as Map?;
    final bankaDovizListesi = (d['bankaDovizler'] as List?)?.cast<Map>() ?? [];
    final nakitDovizListesi = (d['nakitDovizler'] as List?)?.cast<Map>() ?? [];

    final Map<String, double> dovizMiktarlari = {};
    final Map<String, double> dovizKurlar = {};
    for (var t in dovizTurleri) {
      double topMiktar = 0, topTL = 0;
      for (var dv in dovizler.where((dv) => dv['cins'] == t)) {
        topMiktar += (dv['miktar'] as num? ?? 0).toDouble();
        topTL += (dv['tlKarsiligi'] as num? ?? 0).toDouble();
      }
      dovizMiktarlari[t] = topMiktar;
      dovizKurlar[t] = topMiktar > 0 ? topTL / topMiktar : 0;
    }
    final dovizliTurler =
        dovizTurleri.where((t) => (dovizMiktarlari[t] ?? 0) > 0).toList();

    // ── Pulse kanalları ──
    final pulseKanallar = _pulseKanallariniAyir(d);
    final yemekler = pulseKanallar['yemek']!;
    final onlineler = pulseKanallar['online']!;
    final yemekToplam = yemekler.values.fold(0.0, (s, v) => s + v);
    final onlineToplam = onlineler.values.fold(0.0, (s, v) => s + v);
    final pulseOkundu = d['pulseResmiOkundu'] == true;

    final koyu =
        pw.TextStyle(font: fontBold, fontFallback: [font], fontSize: 10);
    final normal =
        pw.TextStyle(font: font, fontFallback: [fontBold], fontSize: 10);

    pw.Widget bolumBaslik(String baslikText, PdfColor renk, {String? toplam}) {
      return pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        color: renk,
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(baslikText,
                style: pw.TextStyle(
                    font: fontBold, color: PdfColors.white, fontSize: 11)),
            if (toplam != null)
              pw.Text(toplam,
                  style: pw.TextStyle(
                      font: fontBold, color: PdfColors.white, fontSize: 11)),
          ],
        ),
      );
    }

    pw.Widget satir(String label, String deger, {pw.TextStyle? style}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: normal),
            pw.Text(deger, style: style ?? koyu),
          ],
        ),
      );
    }

    pw.Widget satirGirinti(String label, String deger, {PdfColor? renk}) {
      final stil = pw.TextStyle(
          font: font, fontSize: 9, color: renk ?? PdfColors.grey700);
      return pw.Padding(
        padding: const pw.EdgeInsets.only(left: 10, top: 1, bottom: 1),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('  $label', style: stil),
            pw.Text(deger,
                style: pw.TextStyle(
                    font: fontBold,
                    fontSize: 9,
                    color: renk ?? PdfColors.grey700)),
          ],
        ),
      );
    }

    final icerik = <pw.Widget>[
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(10),
        color: PdfColor.fromHex('#7B1F2E'),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('$subeAd Günlük Özet',
                style: pw.TextStyle(
                    font: fontBold, color: PdfColors.white, fontSize: 14)),
            pw.Text(_tarihGoster(_secilenTarih),
                style: pw.TextStyle(
                    font: font, color: PdfColors.white, fontSize: 12)),
          ],
        ),
      ),
      pw.SizedBox(height: 8),
      if ((d['gunlukSatisToplami'] as num? ?? 0) > 0)
        pw.Container(
          width: double.infinity,
          color: PdfColors.red700,
          child: pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('GÜNLÜK SATIŞ',
                    style: pw.TextStyle(
                        font: fontBold, color: PdfColors.white, fontSize: 12)),
                pw.Text(fmt(d['gunlukSatisToplami']),
                    style: pw.TextStyle(
                        font: fontBold, color: PdfColors.white, fontSize: 13)),
              ],
            ),
          ),
        ),
      pw.SizedBox(height: 4),
      bolumBaslik('POS TOPLAMI', PdfColors.blueGrey700,
          toplam: fmt(d['toplamPos'])),
      pw.SizedBox(height: 4),

      // ── ÖDEME KANALLARI (Pulse) — PDF ──────────────────────────────────────
      if (pulseOkundu && (yemekler.isNotEmpty || onlineler.isNotEmpty)) ...[
        bolumBaslik('ÖDEME KANALLARI (Pulse)', PdfColor.fromHex('#006064')),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration:
              pw.BoxDecoration(border: pw.Border.all(color: PdfColors.teal200)),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Yemek Kartları
              if (yemekler.isNotEmpty) ...[
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Yemek Kartları',
                        style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: PdfColor.fromHex('#2E7D32'))),
                    pw.Text(fmt(yemekToplam),
                        style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: PdfColor.fromHex('#2E7D32'))),
                  ],
                ),
                ...yemekler.entries.map((e) => satirGirinti(e.key, fmt(e.value),
                    renk: PdfColor.fromHex('#388E3C'))),
              ],
              // Online Ödemeler
              if (onlineler.isNotEmpty) ...[
                if (yemekler.isNotEmpty) pw.SizedBox(height: 4),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Online Ödemeler',
                        style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: PdfColor.fromHex('#1565C0'))),
                    pw.Text(fmt(onlineToplam),
                        style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: PdfColor.fromHex('#1565C0'))),
                  ],
                ),
                ...onlineler.entries.map((e) => satirGirinti(
                    e.key, fmt(e.value),
                    renk: PdfColor.fromHex('#1976D2'))),
              ],
            ],
          ),
        ),
        pw.SizedBox(height: 4),
      ],

      pw.SizedBox(height: 2),
      bolumBaslik('HARCAMALAR', PdfColors.red700,
          toplam: fmt(d['toplamHarcama'])),
      pw.Container(
        padding: const pw.EdgeInsets.all(6),
        decoration:
            pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
        child: pw.Column(
          children: harcamalar
              .where((h) => (h['tutar'] ?? 0) != 0)
              .map((h) => satir(h['aciklama'] ?? 'Harcama', fmt(h['tutar'])))
              .toList(),
        ),
      ),
      pw.SizedBox(height: 6),
      bolumBaslik('KASA ÖZETİ', PdfColors.green700),
      pw.SizedBox(height: 4),
      pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 6),
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          color: PdfColors.blue50,
          border: pw.Border.all(color: PdfColors.blue200),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('TL',
                style: pw.TextStyle(
                    font: fontBold,
                    fontSize: 10,
                    color: PdfColor.fromHex('#1565C0'))),
            pw.SizedBox(height: 4),
            satir('Banka Parası', fmt(d['bankaParasi'])),
            if ((d['devredenFlot'] as num? ?? 0) > 0)
              satir('Devreden Flot', fmt(d['devredenFlot'])),
            if ((d['toplamHarcama'] as num? ?? 0) > 0)
              satir('Harcamalar', fmt(d['toplamHarcama'])),
            if ((d['gunlukFlot'] as num? ?? 0) > 0)
              satir('Günlük Flot', fmt(d['gunlukFlot'])),
            satir('Toplam Nakit', fmt(d['toplamNakitTL'])),
            if (((d['kasaFarki'] ?? 0) as num).abs() >= 0.01)
              pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 4),
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                color: ((d['kasaFarki'] ?? 0) as num) >= 0
                    ? PdfColors.green600
                    : PdfColors.red600,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Kasa Farkı',
                        style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: PdfColors.white)),
                    pw.Text(fmt(d['kasaFarki']),
                        style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: PdfColors.white)),
                  ],
                ),
              ),
            pw.Divider(color: PdfColors.blue200),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Günlük Kasa Kalanı',
                    style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: PdfColor.fromHex('#1565C0'))),
                pw.Text(fmt(d['gunlukKasaKalaniTL']),
                    style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: (_toDouble(d['gunlukKasaKalaniTL']) >= 0)
                            ? PdfColor.fromHex('#1565C0')
                            : PdfColors.red700)),
              ],
            ),
          ],
        ),
      ),
      ...dovizliTurler.map((t) {
        final sembol = dovizSembolleri[t] ?? t;
        final miktar = dovizMiktarlari[t] ?? 0;
        final tlK = miktar * (dovizKurlar[t] ?? 0);
        final bgRenk = t == 'USD'
            ? PdfColors.orange50
            : t == 'EUR'
                ? PdfColors.purple50
                : PdfColors.teal50;
        final yaziRenk = t == 'USD'
            ? PdfColor.fromHex('#E65100')
            : t == 'EUR'
                ? PdfColor.fromHex('#6A1B9A')
                : PdfColor.fromHex('#1B5E20');
        final borderRenk = t == 'USD'
            ? PdfColors.orange200
            : t == 'EUR'
                ? PdfColors.purple200
                : PdfColors.teal200;
        return pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 6),
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
              color: bgRenk,
              border: pw.Border.all(color: borderRenk),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6))),
          child: pw.Column(children: [
            pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('$sembol $t',
                      style: pw.TextStyle(
                          font: fontBold, fontSize: 10, color: yaziRenk)),
                  pw.Text('$sembol ${miktar.toStringAsFixed(2)}',
                      style: pw.TextStyle(
                          font: fontBold, fontSize: 11, color: yaziRenk)),
                ]),
            if (tlK > 0) ...[
              pw.SizedBox(height: 2),
              pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('TL Karşılığı',
                        style: pw.TextStyle(
                            font: font, fontSize: 9, color: yaziRenk)),
                    pw.Text(fmt(tlK),
                        style: pw.TextStyle(
                            font: font, fontSize: 9, color: yaziRenk)),
                  ]),
            ],
          ]),
        );
      }),
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        color: (_toDouble(d['gunlukKasaKalani']) >= 0)
            ? PdfColors.green700
            : PdfColors.red700,
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Günlük Toplam Kasa Kalanı',
                style: pw.TextStyle(
                    font: fontBold, fontSize: 11, color: PdfColors.white)),
            pw.Text(fmt(d['gunlukKasaKalani']),
                style: pw.TextStyle(
                    font: fontBold, fontSize: 11, color: PdfColors.white)),
          ],
        ),
      ),
      pw.SizedBox(height: 6),
      if ((d['toplamNakitCikis'] as num? ?? 0) > 0 ||
          ((d['nakitDovizler'] as List?)?.cast<Map>() ?? [])
              .any((nd) => (nd['miktar'] as num? ?? 0) > 0)) ...[
        bolumBaslik('NAKİT ÇIKIŞ', PdfColor.fromHex('#7B1FA2'),
            toplam: (d['toplamNakitCikis'] as num? ?? 0) > 0
                ? fmt(d['toplamNakitCikis'])
                : null),
        ...((d['nakitCikislar'] as List?)?.cast<Map>() ?? [])
            .where((h) => (h['tutar'] as num? ?? 0) > 0)
            .map((h) => satir(
                h['aciklama']?.toString().isNotEmpty == true
                    ? h['aciklama'].toString()
                    : 'Nakit Çıkış',
                fmt(h['tutar']))),
        ...((d['nakitDovizler'] as List?)?.cast<Map>() ?? [])
            .where((nd) => (nd['miktar'] as num? ?? 0) > 0)
            .map((nd) {
          final cins = nd['cins'] as String? ?? '';
          final sembol = cins == 'USD'
              ? r'$'
              : cins == 'EUR'
                  ? '€'
                  : cins == 'GBP'
                      ? '£'
                      : cins;
          final miktar = (nd['miktar'] as num).toDouble();
          final pdfRenk = cins == 'USD'
              ? PdfColor.fromHex('#E65100')
              : cins == 'EUR'
                  ? PdfColor.fromHex('#6A1B9A')
                  : PdfColor.fromHex('#1B5E20');
          return satir(
            nd['aciklama']?.toString().isNotEmpty == true
                ? nd['aciklama'].toString()
                : 'Nakit $cins Çıkış',
            '$sembol ${miktar.toStringAsFixed(2)}',
            style: pw.TextStyle(font: fontBold, fontSize: 10, color: pdfRenk),
          );
        }),
      ],
      if (anaHarcamalar.isNotEmpty &&
          (d['toplamAnaKasaHarcama'] ?? 0) != 0) ...[
        bolumBaslik('ANA KASA HARCAMALAR', PdfColors.orange700,
            toplam: fmt(d['toplamAnaKasaHarcama'])),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration:
              pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
          child: pw.Column(
              children: anaHarcamalar
                  .where((h) => (h['tutar'] ?? 0) != 0)
                  .map(
                      (h) => satir(h['aciklama'] ?? 'Harcama', fmt(h['tutar'])))
                  .toList()),
        ),
        pw.SizedBox(height: 6),
      ],
      bolumBaslik('ANA KASA ÖZETİ', PdfColors.blue900,
          toplam: fmt(d['anaKasaKalani'])),
      pw.Container(
        padding: const pw.EdgeInsets.all(6),
        decoration:
            pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
        child: pw.Column(children: [
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 4),
            padding: const pw.EdgeInsets.all(6),
            decoration: pw.BoxDecoration(
                color: PdfColors.blue50,
                border: pw.Border.all(color: PdfColors.blue200),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6))),
            child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('TL',
                      style: pw.TextStyle(
                          font: fontBold,
                          fontSize: 10,
                          color: PdfColor.fromHex('#1565C0'))),
                  pw.SizedBox(height: 4),
                  satir('Devreden Ana Kasa', fmt(d['oncekiAnaKasaKalani'])),
                  satir(
                      'Günlük Kasa Kalanı (TL)', fmt(d['gunlukKasaKalaniTL'])),
                  if ((d['bankayaYatirilan'] as num? ?? 0) > 0)
                    satir('Bankaya Yatırılan', fmt(d['bankayaYatirilan'])),
                  if ((d['toplamAnaKasaHarcama'] as num? ?? 0) > 0)
                    satir(
                        'Ana Kasa Harcamalar', fmt(d['toplamAnaKasaHarcama'])),
                  if (((d['nakitCikislar'] as List?)?.cast<Map>() ?? [])
                      .any((h) => (h['tutar'] as num? ?? 0) > 0))
                    satir(
                        'Nakit Çıkış',
                        fmt(((d['nakitCikislar'] as List?)?.cast<Map>() ?? [])
                            .where((h) => (h['tutar'] as num? ?? 0) > 0)
                            .fold<double>(0.0,
                                (s, h) => s + (h['tutar'] as num).toDouble()))),
                  pw.Divider(color: PdfColors.blue200),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    color: (_toDouble(d['anaKasaKalani']) >= 0)
                        ? PdfColors.green700
                        : PdfColors.red700,
                    child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Ana Kasa Kalanı',
                              style: pw.TextStyle(
                                  font: fontBold,
                                  fontSize: 10,
                                  color: PdfColors.white)),
                          pw.Text(fmt(d['anaKasaKalani']),
                              style: pw.TextStyle(
                                  font: fontBold,
                                  fontSize: 10,
                                  color: PdfColors.white)),
                        ]),
                  ),
                ]),
          ),
          ...dovizTurleri.where((t) {
            final kalan = (dovizKalanlar?[t] as num?)?.toDouble() ?? 0;
            final devreden = (oncekiDovizKalanlar?[t] as num?)?.toDouble() ?? 0;
            return kalan != 0 || devreden != 0 || (dovizMiktarlari[t] ?? 0) > 0;
          }).map((t) {
            final bgRenk = t == 'USD'
                ? PdfColors.orange50
                : t == 'EUR'
                    ? PdfColors.purple50
                    : PdfColors.teal50;
            final yaziRenk = t == 'USD'
                ? PdfColors.orange800
                : t == 'EUR'
                    ? PdfColors.purple800
                    : PdfColors.teal800;
            final kalanRenk = t == 'USD'
                ? PdfColors.deepOrange700
                : t == 'EUR'
                    ? PdfColors.purple700
                    : PdfColors.teal700;
            final sembol = dovizSembolleri[t] ?? t;
            final kalan = (dovizKalanlar?[t] as num?)?.toDouble() ?? 0;
            final devreden = (oncekiDovizKalanlar?[t] as num?)?.toDouble() ?? 0;
            double bankaYatan = 0;
            for (var bd in bankaDovizListesi) {
              if (bd['cins'] == t)
                bankaYatan += (bd['miktar'] as num? ?? 0).toDouble();
            }
            return pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 4),
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(
                  color: bgRenk,
                  borderRadius:
                      const pw.BorderRadius.all(pw.Radius.circular(6))),
              child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('$sembol $t',
                        style: pw.TextStyle(
                            font: fontBold, fontSize: 10, color: yaziRenk)),
                    pw.SizedBox(height: 2),
                    satir('Devreden Ana Kasa',
                        '$sembol ${devreden.toStringAsFixed(2)}'),
                    satir('Günlük Kasa Kalanı',
                        '$sembol ${(dovizMiktarlari[t] ?? 0).toStringAsFixed(2)}'),
                    if (bankaYatan > 0)
                      satir('Bankaya Yatırılan',
                          '$sembol ${bankaYatan.toStringAsFixed(2)}'),
                    if (((d['nakitDovizler'] as List?)?.cast<Map>() ?? []).any(
                        (nd) =>
                            nd['cins'] == t && (nd['miktar'] as num? ?? 0) > 0))
                      satir('Nakit Çıkış',
                          '$sembol ${((d['nakitDovizler'] as List?)?.cast<Map>() ?? []).where((nd) => nd['cins'] == t && (nd['miktar'] as num? ?? 0) > 0).fold<double>(0.0, (s, nd) => s + (nd['miktar'] as num).toDouble()).toStringAsFixed(2)}'),
                    pw.SizedBox(height: 4),
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      color: kalan >= 0 ? kalanRenk : PdfColors.red700,
                      child: pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('Ana Kasa Kalanı',
                                style: pw.TextStyle(
                                    font: fontBold,
                                    fontSize: 10,
                                    color: PdfColors.white)),
                            pw.Text('$sembol ${kalan.toStringAsFixed(2)}',
                                style: pw.TextStyle(
                                    font: fontBold,
                                    fontSize: 10,
                                    color: PdfColors.white)),
                          ]),
                    ),
                  ]),
            );
          }),
        ]),
      ),
      if (transferListesi.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        () {
          double netT = 0;
          for (final t in transferListesi) {
            final kat = t['kategori'] as String? ?? '';
            final tutar = ((t['tutar'] ?? 0) as num).toDouble();
            if (kat == 'GELEN') netT += tutar;
            if (kat == 'GİDEN') netT -= tutar;
          }
          final netPrefix = netT >= 0 ? '+' : '-';
          return bolumBaslik('TRANSFERLER', PdfColors.blueGrey600,
              toplam: '$netPrefix ${fmt(netT.abs())}');
        }(),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration:
              pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
          child: pw.Column(
              children: transferListesi.map((t) {
            final kat = t['kategori'] as String? ?? '';
            final isGiden = kat == 'GİDEN';
            final renk = isGiden ? PdfColors.red700 : PdfColors.blue900;
            final prefix = isGiden ? '- ' : '+ ';
            final aciklama = (t['aciklama'] as String?)?.isNotEmpty == true
                ? t['aciklama'] as String
                : '';
            final hedefSube = (t['hedefSube'] as String?)?.isNotEmpty == true
                ? t['hedefSube'] as String
                : '';
            final hedefSubeAd =
                (t['hedefSubeAd'] as String?)?.isNotEmpty == true
                    ? t['hedefSubeAd'] as String
                    : hedefSube;
            final kaynakSube = (t['kaynakSube'] as String?)?.isNotEmpty == true
                ? t['kaynakSube'] as String
                : '';
            final kaynakSubeAd =
                (t['kaynakSubeAd'] as String?)?.isNotEmpty == true
                    ? t['kaynakSubeAd'] as String
                    : (kaynakSube.isNotEmpty ? kaynakSube : '');
            final subeLabel = isGiden ? hedefSubeAd : kaynakSubeAd;
            final aciklamaTemiz = aciklama == subeLabel ||
                    aciklama == (isGiden ? hedefSube : kaynakSube)
                ? ''
                : aciklama;
            final labelText = [
              kat,
              if (subeLabel.isNotEmpty) subeLabel,
              if (aciklamaTemiz.isNotEmpty) aciklamaTemiz
            ].join(' - ');
            return pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.RichText(
                        text: pw.TextSpan(children: [
                      pw.TextSpan(
                          text: labelText,
                          style: pw.TextStyle(
                              font: fontBold, fontSize: 10, color: renk)),
                    ])),
                    pw.Text('$prefix${fmt(t['tutar'])}',
                        style: pw.TextStyle(
                            font: fontBold, fontSize: 10, color: renk)),
                  ]),
            );
          }).toList()),
        ),
      ],
      if (digerAlimlarListesi.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        () {
          double toplamDiger = digerAlimlarListesi.fold(
              0.0, (s, t) => s + ((t['tutar'] as num? ?? 0).toDouble()));
          return bolumBaslik('DİĞER ALIMLAR', PdfColors.grey,
              toplam: fmt(toplamDiger));
        }(),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration:
              pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
          child: pw.Column(
              children: digerAlimlarListesi
                  .where((t) => (t['tutar'] ?? 0) != 0)
                  .map((t) => satir(t['aciklama'] ?? '', fmt(t['tutar'])))
                  .toList()),
        ),
      ],
      if (tutarsizTransferler.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        bolumBaslik('⚠ TUTARSIZ TRANSFER', PdfColors.red700),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.red300),
              color: PdfColors.red50),
          child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: tutarsizTransferler.map((t) {
                final gonderesSube = t['gonderenSubeAd'] as String? ??
                    t['gonderesSube'] as String? ??
                    '?';
                final alanSube = t['alanSubeAd'] as String? ??
                    t['alanSube'] as String? ??
                    '?';
                final aciklama = t['aciklama'] as String? ?? '';
                final gonderilenTutar =
                    (t['gonderilenTutar'] as num? ?? t['tutar'] as num? ?? 0)
                        .toDouble();
                final onaylananTutar =
                    (t['onaylananTutar'] as num? ?? t['tutar'] as num? ?? 0)
                        .toDouble();
                final nedenMetin =
                    'Gönderilen: ${fmt(gonderilenTutar)} / Onaylanan: ${fmt(onaylananTutar)}';
                return pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 3),
                  child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Row(
                            mainAxisAlignment:
                                pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text('$gonderesSube → $alanSube',
                                  style: pw.TextStyle(
                                      font: fontBold,
                                      fontSize: 10,
                                      color: PdfColors.red700)),
                              pw.Text(fmt(gonderilenTutar),
                                  style: pw.TextStyle(
                                      font: fontBold,
                                      fontSize: 10,
                                      color: PdfColors.red700)),
                            ]),
                        if (aciklama.isNotEmpty)
                          pw.Text('  Açıklama: $aciklama',
                              style: pw.TextStyle(
                                  font: font,
                                  fontSize: 9,
                                  color: PdfColors.grey700)),
                        pw.Text('  $nedenMetin',
                            style: pw.TextStyle(
                                font: font,
                                fontSize: 9,
                                color: PdfColors.orange700)),
                      ]),
                );
              }).toList()),
        ),
      ],
    ];

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(16),
        build: (context) {
          final pageW = PdfPageFormat.a4.availableWidth - 32;
          return pw.Center(
            child: pw.FittedBox(
              fit: pw.BoxFit.contain,
              alignment: pw.Alignment.center,
              child: pw.SizedBox(
                width: pageW,
                child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                    mainAxisSize: pw.MainAxisSize.min,
                    children: icerik),
              ),
            ),
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (_) => pdf.save());
  }

  double _aylikSatisToplami = 0;

  Future<void> _kayitYukle() async {
    setState(() => _yukleniyor = true);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(_secilenSube)
          .collection('gunluk')
          .doc(_tarihKey(_secilenTarih))
          .get();

      double aylikToplam = 0;
      try {
        final ayBas =
            '${_secilenTarih.year}-${_secilenTarih.month.toString().padLeft(2, '0')}-01';
        final gun = _tarihKey(_secilenTarih);
        final ayKayitlar = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(_secilenSube)
            .collection('gunluk')
            .where('tarih', isGreaterThanOrEqualTo: ayBas)
            .where('tarih', isLessThanOrEqualTo: gun)
            .get();
        for (var k in ayKayitlar.docs) {
          aylikToplam +=
              ((k.data()['gunlukSatisToplami'] as num?) ?? 0).toDouble();
        }
      } catch (_) {}

      setState(() {
        _kayit = doc.exists ? doc.data() : null;
        _aylikSatisToplami = aylikToplam;
        _yukleniyor = false;
      });

      try {
        final tarihKey = _tarihKey(_secilenTarih);
        final snap1 = await FirebaseFirestore.instance
            .collection('onaylananTransferler')
            .where('tarih', isEqualTo: tarihKey)
            .where('alanSube', isEqualTo: _secilenSube)
            .where('tutarsiz', isEqualTo: true)
            .get();
        final snap2 = await FirebaseFirestore.instance
            .collection('onaylananTransferler')
            .where('tarih', isEqualTo: tarihKey)
            .where('gonderesSube', isEqualTo: _secilenSube)
            .where('tutarsiz', isEqualTo: true)
            .get();
        final liste = [
          ...snap1.docs.map((d) => {...d.data(), 'docId': d.id}),
          ...snap2.docs.map((d) => {...d.data(), 'docId': d.id}),
        ];
        if (mounted) setState(() => _tutarsizTransferler = liste);
      } catch (_) {}
    } catch (_) {
      setState(() {
        _kayit = null;
        _aylikSatisToplami = 0;
        _yukleniyor = false;
      });
    }
  }

  Widget _ozetTarihNavBar() {
    final yonetici = widget.gecmisGunHakki == -1;
    final bugun = DateTime.now();
    final enEskiTarih = yonetici
        ? DateTime(2020)
        : bugun.subtract(Duration(days: widget.gecmisGunHakki));
    final geriAktif =
        widget.gecmisGunHakki != 0 && _secilenTarih.isAfter(enEskiTarih);
    final ileriAktif =
        _secilenTarih.isBefore(DateTime(bugun.year, bugun.month, bugun.day));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 20),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          constraints: const BoxConstraints(minWidth: 28),
          onPressed: geriAktif
              ? () {
                  setState(() => _secilenTarih =
                      _secilenTarih.subtract(const Duration(days: 1)));
                  _kayitYukle();
                }
              : null,
          disabledColor: Colors.white30,
        ),
        GestureDetector(
          onTap: _tarihSec,
          child: Text(_tarihGoster(_secilenTarih),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right, color: Colors.white, size: 20),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          constraints: const BoxConstraints(minWidth: 28),
          onPressed: ileriAktif
              ? () {
                  setState(() => _secilenTarih =
                      _secilenTarih.add(const Duration(days: 1)));
                  _kayitYukle();
                }
              : null,
          disabledColor: Colors.white30,
        ),
      ],
    );
  }

  Future<void> _tarihSec() async {
    final yonetici = widget.gecmisGunHakki == -1;
    if (widget.gecmisGunHakki == 0 && !yonetici) return;
    final bugun = DateTime.now();
    final firstDate = yonetici
        ? DateTime(2020)
        : bugun.subtract(Duration(days: widget.gecmisGunHakki));
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _secilenTarih,
      firstDate: firstDate,
      lastDate: bugun,
      helpText: 'Tarih Seçin',
      cancelText: 'İptal',
      confirmText: 'Seç',
    );
    if (picked != null && picked != _secilenTarih) {
      setState(() => _secilenTarih = picked);
      _kayitYukle();
    }
  }

  String _fmt(double val) {
    final parts = val.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final decPart = parts[1];
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
      buffer.write(intPart[i]);
    }
    return '${buffer.toString()},$decPart';
  }

  String _sembol(String t) => t == 'USD'
      ? '\$'
      : t == 'EUR'
          ? '€'
          : '£';
  double _toDouble(dynamic val) => val == null ? 0 : (val as num).toDouble();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF01579B), Color(0xFF0288D1), Color(0xFF29B6F6)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
        ),
        title: widget.subeler.length > 1
            ? DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _secilenSube,
                  dropdownColor: const Color(0xFF7B1F2E),
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                  isDense: true,
                  isExpanded: true,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                  selectedItemBuilder: (context) => widget.subeler
                      .map((s) => Text('${_subeAdlari[s] ?? s} Günlük Özet',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1))
                      .toList(),
                  items: widget.subeler
                      .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(_subeAdlari[s] ?? s,
                              style: const TextStyle(color: Colors.white))))
                      .toList(),
                  onChanged: (yeniSube) {
                    if (yeniSube != null && yeniSube != _secilenSube) {
                      setState(() => _secilenSube = yeniSube);
                      _kayitYukle();
                    }
                  },
                ),
              )
            : Text('${_subeAdlari[_secilenSube] ?? _secilenSube} Günlük Özet'),
        centerTitle: false,
        backgroundColor: const Color(0xFF7B1F2E),
        foregroundColor: Colors.white,
        actions: [
          if (_kayit != null) ...[
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              tooltip: 'Düzenle',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                      builder: (_) => OnHazirlikEkrani(
                          subeKodu: _secilenSube,
                          subeler: widget.subeler,
                          baslangicTarihi: _secilenTarih,
                          gecmisGunHakki: widget.gecmisGunHakki))),
            ),
            IconButton(
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              tooltip: 'PDF',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => _pdfOlustur(_kayit!,
                  aylikSatisToplami: _aylikSatisToplami,
                  tutarsizTransferler: _tutarsizTransferler),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.table_chart, size: 18),
            tooltip: 'Excel',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => _excelAralikSec(),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Container(
            color: const Color(0xFF6B1828),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _ozetTarihNavBar(),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_yukleniyor)
              const LinearProgressIndicator(
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                  color: Color(0xFF7B1F2E)),
            if (!_yukleniyor && _kayit == null)
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14)),
                child: Column(children: [
                  Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
                  const SizedBox(height: 12),
                  Text(
                      '${_tarihGoster(_secilenTarih)} tarihinde kayıt bulunamadı.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600], fontSize: 15)),
                ]),
              )
            else if (_kayit != null)
              _ozetIcerik(_kayit!),
          ],
        ),
      ),
    );
  }

  Widget _ozetIcerik(Map<String, dynamic> d) {
    final harcamalar = (d['harcamalar'] as List?)?.cast<Map>() ?? [];
    final anaHarcamalar = (d['anaKasaHarcamalari'] as List?)?.cast<Map>() ?? [];
    final dovizler = (d['dovizler'] as List?)?.cast<Map>() ?? [];
    final dovizKalanlar = d['dovizAnaKasaKalanlari'] as Map?;
    final oncekiDovizKalanlar = d['oncekiDovizAnaKasaKalanlari'] as Map?;
    final bankaDovizListesi = (d['bankaDovizler'] as List?)?.cast<Map>() ?? [];
    final nakitDovizListesi = (d['nakitDovizler'] as List?)?.cast<Map>() ?? [];
    final toplamNakitCikis = _toDouble(d['toplamNakitCikis']);
    final toplamPos = _toDouble(d['toplamPos']);
    final toplamHarcama = _toDouble(d['toplamHarcama']);
    final gunlukSatisToplami = _toDouble(d['gunlukSatisToplami']);
    final devredenFlot = _toDouble(d['devredenFlot']);
    final flotTutari = _toDouble(d['gunlukFlot']);
    final kasaFarki = _toDouble(d['kasaFarki']);
    final gunlukKasaKalani = _toDouble(d['gunlukKasaKalani']);
    final gunlukKasaKalaniTL = _toDouble(d['gunlukKasaKalaniTL']);
    final toplamAnaKasaHarcama = _toDouble(d['toplamAnaKasaHarcama']);
    final bankayaYatirilan = _toDouble(d['bankayaYatirilan']);
    final anaKasaKalani = _toDouble(d['anaKasaKalani']);
    final oncekiAnaKasaKalani = _toDouble(d['oncekiAnaKasaKalani']);

    final List<String> dovizTurleri = ['USD', 'EUR', 'GBP'];
    final dovizliTurler = dovizTurleri
        .where((t) =>
            dovizler.any((dv) => dv['cins'] == t && (dv['miktar'] ?? 0) != 0))
        .toList();

    Map<String, double> dovizMiktarlari = {};
    Map<String, double> dovizKurlar = {};
    for (var t in dovizTurleri) {
      double topMiktar = 0, topTL = 0;
      for (var dv in dovizler.where((dv) => dv['cins'] == t)) {
        topMiktar += _toDouble(dv['miktar']);
        topTL += _toDouble(dv['tlKarsiligi']);
      }
      dovizMiktarlari[t] = topMiktar;
      dovizKurlar[t] = topMiktar > 0 ? topTL / topMiktar : 0;
    }

    // ── Pulse kanalları ──
    final pulseKanallar = _pulseKanallariniAyir(d);
    final yemekler = pulseKanallar['yemek']!;
    final onlineler = pulseKanallar['online']!;
    final yemekToplam = yemekler.values.fold(0.0, (s, v) => s + v);
    final onlineToplam = onlineler.values.fold(0.0, (s, v) => s + v);
    final pulseOkundu = d['pulseResmiOkundu'] == true;

    return Column(
      children: [
        // Günlük Satış
        if (gunlukSatisToplami > 0)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.red[700],
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.red.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 3))
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(children: [
                    Icon(Icons.trending_up, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text('GÜNLÜK SATIŞ',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            letterSpacing: 1)),
                  ]),
                  Text(_fmt(gunlukSatisToplami),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18)),
                ],
              ),
            ),
          ),

        // POS
        _bolum(
            renk: const Color(0xFF0288D1),
            ikon: Icons.credit_card,
            baslik: 'POS TOPLAMI',
            toplam: _fmt(toplamPos),
            hideBody: true,
            child: const SizedBox.shrink()),
        const SizedBox(height: 12),

        // ── ÖDEME KANALLARI (Pulse) ──────────────────────────────────────────
        if (pulseOkundu && (yemekler.isNotEmpty || onlineler.isNotEmpty)) ...[
          _bolum(
            renk: const Color(0xFF00695C),
            ikon: Icons.account_balance_wallet_outlined,
            baslik: 'ÖDEME KANALLARI',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Yemek Kartları
                if (yemekler.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Yemek Kartları',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF2E7D32))),
                      Text(_fmt(yemekToplam),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF2E7D32))),
                    ],
                  ),
                  ...yemekler.entries.map((e) => Padding(
                        padding: const EdgeInsets.only(left: 12, top: 3),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(e.key,
                                style: TextStyle(
                                    fontSize: 13, color: Colors.grey[700])),
                            Text(_fmt(e.value),
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey[700],
                                    fontWeight: FontWeight.w500)),
                          ],
                        ),
                      )),
                ],
                // Online Ödemeler
                if (onlineler.isNotEmpty) ...[
                  if (yemekler.isNotEmpty) const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Online Ödemeler',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF1565C0))),
                      Text(_fmt(onlineToplam),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF1565C0))),
                    ],
                  ),
                  ...onlineler.entries.map((e) => Padding(
                        padding: const EdgeInsets.only(left: 12, top: 3),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(e.key,
                                style: TextStyle(
                                    fontSize: 13, color: Colors.grey[700])),
                            Text(_fmt(e.value),
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey[700],
                                    fontWeight: FontWeight.w500)),
                          ],
                        ),
                      )),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Harcamalar
        _bolum(
            renk: const Color(0xFFE53935),
            ikon: Icons.receipt_long,
            baslik: 'HARCAMALAR',
            toplam: _fmt(toplamHarcama),
            child: Column(
                children: harcamalar
                    .where((h) => (h['tutar'] ?? 0) != 0)
                    .map((h) => _kalemSatiri(
                        h['aciklama']?.isEmpty ?? true
                            ? 'Harcama'
                            : h['aciklama'],
                        _fmt(_toDouble(h['tutar']))))
                    .toList())),
        const SizedBox(height: 12),

        // Kasa Özeti
        _bolum(
          renk: const Color(0xFF2E7D32),
          ikon: Icons.summarize,
          baslik: 'KASA ÖZETİ',
          child: Column(children: [
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                  color: const Color(0xFFE3F2FD),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF90CAF9))),
              child: Column(children: [
                const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Text('TL',
                          style: TextStyle(
                              color: Color(0xFF1565C0),
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ])),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Banka Parası',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF1976D2))),
                      Text(_fmt(_toDouble(d['bankaParasi'])),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF1565C0))),
                    ]),
                if (devredenFlot > 0) ...[
                  const SizedBox(height: 2),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Devreden Flot',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF1976D2))),
                        Text(_fmt(devredenFlot),
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF1565C0))),
                      ]),
                ],
                if (_toDouble(d['toplamHarcama']) > 0) ...[
                  const SizedBox(height: 2),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Harcamalar',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF1976D2))),
                        Text(_fmt(_toDouble(d['toplamHarcama'])),
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF1565C0))),
                      ]),
                ],
                if (flotTutari > 0) ...[
                  const SizedBox(height: 2),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Günlük Flot',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF1976D2))),
                        Text(_fmt(flotTutari),
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF1565C0))),
                      ]),
                ],
                const SizedBox(height: 2),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Toplam Nakit',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF1976D2))),
                      Text(_fmt(_toDouble(d['toplamNakitTL'])),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF1565C0))),
                    ]),
                if (kasaFarki.abs() >= 0.01) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                        color: kasaFarki >= 0
                            ? Colors.green[600]
                            : Colors.red[600],
                        borderRadius: BorderRadius.circular(6)),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Kasa Farkı',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                          Text(_fmt(kasaFarki),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                        ]),
                  ),
                ],
                const Divider(height: 12, color: Color(0xFF90CAF9)),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Günlük Kasa Kalanı',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF1976D2))),
                      Text(_fmt(gunlukKasaKalaniTL),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: gunlukKasaKalaniTL >= 0
                                  ? const Color(0xFF1565C0)
                                  : Colors.red[700])),
                    ]),
              ]),
            ),
            ...dovizliTurler.map((t) {
              final sembol = _sembol(t);
              final miktar = dovizMiktarlari[t] ?? 0;
              final tlK = miktar * (dovizKurlar[t] ?? 0);
              final bgRenk = t == 'USD'
                  ? const Color(0xFFFFF8E1)
                  : t == 'EUR'
                      ? const Color(0xFFF3E5F5)
                      : const Color(0xFFE8F5E9);
              final yaziRenk = t == 'USD'
                  ? const Color(0xFFE65100)
                  : t == 'EUR'
                      ? const Color(0xFF6A1B9A)
                      : const Color(0xFF1B5E20);
              final borderRenk = t == 'USD'
                  ? const Color(0xFFFFCC80)
                  : t == 'EUR'
                      ? const Color(0xFFCE93D8)
                      : const Color(0xFFA5D6A7);
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                    color: bgRenk,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: borderRenk)),
                child: Column(children: [
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('$sembol $t',
                            style: TextStyle(
                                color: yaziRenk,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                        Text('$sembol ${miktar.toStringAsFixed(2)}',
                            style: TextStyle(
                                color: yaziRenk,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                      ]),
                  if (tlK > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('TL Karşılığı',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: yaziRenk.withOpacity(0.8))),
                          Text(_fmt(tlK),
                              style: TextStyle(fontSize: 11, color: yaziRenk)),
                        ]),
                  ],
                ]),
              );
            }),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                  color: gunlukKasaKalani >= 0
                      ? Colors.green[700]
                      : Colors.red[700],
                  borderRadius: BorderRadius.circular(10)),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Günlük Toplam Kasa Kalanı',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                    Text(_fmt(gunlukKasaKalani),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                  ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),

        // Nakit Çıkış
        if (toplamNakitCikis > 0 ||
            nakitDovizListesi.any((nd) => (nd['miktar'] as num? ?? 0) > 0)) ...[
          _bolum(
            renk: const Color(0xFF7B1FA2),
            ikon: Icons.payments_outlined,
            baslik: 'NAKİT ÇIKIŞ',
            toplam: toplamNakitCikis > 0 ? _fmt(toplamNakitCikis) : null,
            child: Column(children: [
              if (toplamNakitCikis > 0)
                ...((d['nakitCikislar'] as List?)?.cast<Map>() ?? [])
                    .where((h) => (h['tutar'] as num? ?? 0) > 0)
                    .map((h) {
                  final aciklama = (h['aciklama'] as String? ?? '').trim();
                  return _kalemSatiri(
                      aciklama.isNotEmpty ? 'TL - $aciklama' : 'Nakit Çıkış TL',
                      _fmt((h['tutar'] as num).toDouble()));
                }),
              ...nakitDovizListesi
                  .where((nd) => (nd['miktar'] as num? ?? 0) > 0)
                  .map((nd) {
                final cins = nd['cins'] as String? ?? '';
                final sembol = cins == 'USD'
                    ? r'$'
                    : cins == 'EUR'
                        ? '€'
                        : cins == 'GBP'
                            ? '£'
                            : cins;
                final aciklama = (nd['aciklama'] as String? ?? '').trim();
                return _kalemSatiri(
                    aciklama.isNotEmpty
                        ? '$cins - $aciklama'
                        : 'Nakit Çıkış $cins',
                    '$sembol ${(nd['miktar'] as num).toStringAsFixed(2)}');
              }),
            ]),
          ),
          const SizedBox(height: 12),
        ],

        // Ana Kasa Harcamalar
        if (toplamAnaKasaHarcama > 0) ...[
          _bolum(
            renk: const Color(0xFFE65100),
            ikon: Icons.money_off,
            baslik: 'ANA KASA HARCAMALAR',
            toplam: _fmt(toplamAnaKasaHarcama),
            child: Column(
                children: anaHarcamalar
                    .where((h) => (h['tutar'] ?? 0) != 0)
                    .map((h) => _kalemSatiri(
                        h['aciklama']?.isEmpty ?? true
                            ? 'Harcama'
                            : h['aciklama'],
                        _fmt(_toDouble(h['tutar']))))
                    .toList()),
          ),
          const SizedBox(height: 12),
        ],

        // Ana Kasa Özeti
        _bolum(
          renk: const Color(0xFF1565C0),
          ikon: Icons.account_balance,
          baslik: 'ANA KASA ÖZETİ',
          child: Column(children: [
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                  color: const Color(0xFFE3F2FD),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF90CAF9))),
              child: Column(children: [
                const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Text('TL',
                          style: TextStyle(
                              color: Color(0xFF1565C0),
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ])),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Devreden Ana Kasa',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF1976D2))),
                      Text(_fmt(oncekiAnaKasaKalani),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF1565C0))),
                    ]),
                const SizedBox(height: 2),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Günlük Kasa Kalanı (TL)',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF1976D2))),
                      Text(_fmt(gunlukKasaKalaniTL),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF1565C0))),
                    ]),
                if (bankayaYatirilan > 0) ...[
                  const SizedBox(height: 2),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Bankaya Yatırılan',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF1976D2))),
                        Text(_fmt(bankayaYatirilan),
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF1565C0))),
                      ]),
                ],
                if (toplamAnaKasaHarcama > 0) ...[
                  const SizedBox(height: 2),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Ana Kasa Harcamalar',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF1976D2))),
                        Text(_fmt(toplamAnaKasaHarcama),
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF1565C0))),
                      ]),
                ],
                if (((d['nakitCikislar'] as List?)?.cast<Map>() ?? [])
                    .any((h) => (h['tutar'] as num? ?? 0) > 0)) ...[
                  const SizedBox(height: 2),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Nakit Çıkış',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF1976D2))),
                        Text(
                            _fmt(((d['nakitCikislar'] as List?)?.cast<Map>() ??
                                    [])
                                .where((h) => (h['tutar'] as num? ?? 0) > 0)
                                .fold<double>(
                                    0.0,
                                    (s, h) =>
                                        s + (h['tutar'] as num).toDouble())),
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF1565C0))),
                      ]),
                ],
                const Divider(height: 10, color: Color(0xFF90CAF9)),
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: anaKasaKalani >= 0
                          ? Colors.green[700]
                          : Colors.red[700],
                      borderRadius: BorderRadius.circular(6)),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Ana Kasa Kalanı',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                        Text(_fmt(anaKasaKalani),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                      ]),
                ),
              ]),
            ),
            ...dovizTurleri.where((t) {
              final kalan = _toDouble(dovizKalanlar?[t]);
              final devreden = _toDouble(oncekiDovizKalanlar?[t]);
              final miktar = dovizMiktarlari[t] ?? 0;
              return kalan != 0 || devreden != 0 || miktar > 0;
            }).map((t) {
              final sembol = _sembol(t);
              final kalan = _toDouble(dovizKalanlar?[t]);
              final devreden = _toDouble(oncekiDovizKalanlar?[t]);
              double bankaYatan = 0;
              for (var bd in bankaDovizListesi) {
                if (bd['cins'] == t) bankaYatan += _toDouble(bd['miktar']);
              }
              double nakitCikisToplam = 0;
              for (var nd in nakitDovizListesi) {
                if (nd['cins'] == t)
                  nakitCikisToplam += _toDouble(nd['miktar']);
              }
              final bgRenk = t == 'USD'
                  ? const Color(0xFFFFF8E1)
                  : t == 'EUR'
                      ? const Color(0xFFF3E5F5)
                      : const Color(0xFFE8F5E9);
              final yaziRenk = t == 'USD'
                  ? const Color(0xFFE65100)
                  : t == 'EUR'
                      ? const Color(0xFF6A1B9A)
                      : const Color(0xFF1B5E20);
              final borderRenk = t == 'USD'
                  ? const Color(0xFFFFCC80)
                  : t == 'EUR'
                      ? const Color(0xFFCE93D8)
                      : const Color(0xFFA5D6A7);
              return Container(
                margin: const EdgeInsets.only(top: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: bgRenk,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: borderRenk)),
                child: Column(children: [
                  Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Text('$sembol $t',
                            style: TextStyle(
                                color: yaziRenk,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                      ])),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Devreden Ana Kasa',
                            style: TextStyle(
                                fontSize: 12,
                                color: yaziRenk.withOpacity(0.8))),
                        Text('$sembol ${devreden.toStringAsFixed(2)}',
                            style: TextStyle(fontSize: 12, color: yaziRenk)),
                      ]),
                  const SizedBox(height: 2),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Günlük Kasa Kalanı',
                            style: TextStyle(
                                fontSize: 12,
                                color: yaziRenk.withOpacity(0.8))),
                        Text(
                            '$sembol ${(dovizMiktarlari[t] ?? 0).toStringAsFixed(2)}',
                            style: TextStyle(fontSize: 12, color: yaziRenk)),
                      ]),
                  if (bankaYatan > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Bankaya Yatırılan',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: yaziRenk.withOpacity(0.8))),
                          Text('$sembol ${bankaYatan.toStringAsFixed(2)}',
                              style: TextStyle(fontSize: 12, color: yaziRenk)),
                        ]),
                  ],
                  if (nakitCikisToplam > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Nakit Çıkış',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: yaziRenk.withOpacity(0.8))),
                          Text('$sembol ${nakitCikisToplam.toStringAsFixed(2)}',
                              style: TextStyle(fontSize: 12, color: yaziRenk)),
                        ]),
                  ],
                  const Divider(height: 10),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Ana Kasa Kalanı',
                            style: TextStyle(
                                color: yaziRenk,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                        Text('$sembol ${kalan.toStringAsFixed(2)}',
                            style: TextStyle(
                                color: kalan >= 0 ? yaziRenk : Colors.red[700],
                                fontWeight: FontWeight.bold,
                                fontSize: 16)),
                      ]),
                ]),
              );
            }),
          ]),
        ),
        const SizedBox(height: 12),

        // Transferler
        Builder(builder: (context) {
          final transferListesi =
              (d['transferler'] as List?)?.cast<Map>() ?? [];
          final sadeceTrf = transferListesi
              .where(
                  (t) => t['kategori'] == 'GİDEN' || t['kategori'] == 'GELEN')
              .toList();
          if (sadeceTrf.isEmpty) return const SizedBox.shrink();
          final gidenler =
              sadeceTrf.where((t) => t['kategori'] == 'GİDEN').toList();
          final gelenler =
              sadeceTrf.where((t) => t['kategori'] == 'GELEN').toList();
          double toplamGiden =
              gidenler.fold(0.0, (s, t) => s + _toDouble(t['tutar']));
          double toplamGelen =
              gelenler.fold(0.0, (s, t) => s + _toDouble(t['tutar']));
          double netTransfer = toplamGelen - toplamGiden;

          return _bolum(
            renk: const Color(0xFF546E7A),
            ikon: Icons.swap_horiz,
            baslik: 'TRANSFERLER',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (gidenler.isNotEmpty) ...[
                Text('GİDEN',
                    style: TextStyle(
                        color: Colors.red[700],
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
                ...gidenler.map((t) {
                  final hedef = (t['hedefSube'] as String?)?.isNotEmpty == true
                      ? t['hedefSube'] as String
                      : '';
                  final hedefAd =
                      (t['hedefSubeAd'] as String?)?.isNotEmpty == true
                          ? t['hedefSubeAd'] as String
                          : hedef;
                  final aciklama = t['aciklama'] as String? ?? '';
                  final aciklamaTemiz =
                      aciklama == hedefAd || aciklama == hedef ? '' : aciklama;
                  final label = [
                    if (hedefAd.isNotEmpty) hedefAd,
                    if (aciklamaTemiz.isNotEmpty) aciklamaTemiz
                  ].join(' - ');
                  return _kalemSatiriRenk(label.isEmpty ? 'Transfer' : label,
                      '- ${_fmt(_toDouble(t['tutar']))}', Colors.red[700]!);
                }),
                const SizedBox(height: 4),
              ],
              if (gelenler.isNotEmpty) ...[
                const Text('GELEN',
                    style: TextStyle(
                        color: Color(0xFF0288D1),
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
                ...gelenler.map((t) {
                  final kaynak =
                      (t['kaynakSube'] as String?)?.isNotEmpty == true
                          ? t['kaynakSube'] as String
                          : '';
                  final kaynakAd =
                      (t['kaynakSubeAd'] as String?)?.isNotEmpty == true
                          ? t['kaynakSubeAd'] as String
                          : (_subeAdlari[kaynak]?.isNotEmpty == true
                              ? _subeAdlari[kaynak]!
                              : kaynak);
                  final aciklama = t['aciklama'] as String? ?? '';
                  final aciklamaTemiz =
                      aciklama == kaynakAd || aciklama == kaynak
                          ? ''
                          : aciklama;
                  final label = [
                    if (kaynakAd.isNotEmpty) kaynakAd,
                    if (aciklamaTemiz.isNotEmpty) aciklamaTemiz
                  ].join(' - ');
                  return _kalemSatiriRenk(
                      label.isEmpty ? 'Transfer' : label,
                      '+ ${_fmt(_toDouble(t['tutar']))}',
                      const Color(0xFF0288D1));
                }),
                const SizedBox(height: 4),
              ],
              if (toplamGiden > 0 || toplamGelen > 0) ...[
                const Divider(),
                if (toplamGiden > 0)
                  _kalemSatiriRenk('Toplam Giden', '- ${_fmt(toplamGiden)}',
                      Colors.red[700]!),
                if (toplamGelen > 0)
                  _kalemSatiriRenk('Toplam Gelen', '+ ${_fmt(toplamGelen)}',
                      const Color(0xFF0288D1)),
                if (toplamGiden > 0 && toplamGelen > 0)
                  _kalemSatiriBold('Net Transfer',
                      '${netTransfer >= 0 ? '+' : '-'} ${_fmt(netTransfer.abs())}',
                      renk: netTransfer >= 0
                          ? const Color(0xFF0288D1)
                          : Colors.red[700]!),
              ],
            ]),
          );
        }),
        const SizedBox(height: 12),

        // Tutarsız Transfer Uyarısı
        if (_tutarsizTransferler.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red[300]!)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                    color: Colors.red[700],
                    borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(12),
                        topRight: Radius.circular(12))),
                child: Row(children: [
                  const Icon(Icons.warning_amber,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Text('TUTARSIZ TRANSFER (${_tutarsizTransferler.length})',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          letterSpacing: 0.5)),
                ]),
              ),
              ..._tutarsizTransferler.map((t) {
                final gonderesSube = t['gonderenSubeAd'] as String? ??
                    t['gonderesSube'] as String? ??
                    '?';
                final alanSube = t['alanSubeAd'] as String? ??
                    t['alanSube'] as String? ??
                    '?';
                final aciklama = t['aciklama'] as String? ?? '';
                final gonderilenTutar =
                    (t['gonderilenTutar'] as num? ?? t['tutar'] as num? ?? 0)
                        .toDouble();
                final onaylananTutar =
                    (t['onaylananTutar'] as num? ?? t['tutar'] as num? ?? 0)
                        .toDouble();
                final tutarsiz =
                    (gonderilenTutar - onaylananTutar).abs() > 0.01;
                final nedenMetin = tutarsiz
                    ? 'Gönderilen: ${_fmt(gonderilenTutar)} / Onaylanan: ${_fmt(onaylananTutar)}'
                    : 'Kayıt uyumsuz';
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                      border:
                          Border(bottom: BorderSide(color: Colors.red[200]!))),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.swap_horiz,
                              size: 14, color: Colors.red[700]),
                          const SizedBox(width: 6),
                          Expanded(
                              child: Text('$gonderesSube → $alanSube',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red[800],
                                      fontSize: 13))),
                          Text(_fmt(gonderilenTutar),
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.red[700],
                                  fontSize: 13)),
                        ]),
                        if (aciklama.isNotEmpty)
                          Padding(
                              padding: const EdgeInsets.only(top: 2, left: 20),
                              child: Text(aciklama,
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey[700]))),
                        Padding(
                            padding: const EdgeInsets.only(top: 2, left: 20),
                            child: Text(nedenMetin,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.orange[800],
                                    fontStyle: FontStyle.italic))),
                      ]),
                );
              }),
            ]),
          ),

        // Diğer Alımlar
        Builder(builder: (context) {
          final digerListesiRaw =
              (d['digerAlimlar'] as List?)?.cast<Map>() ?? [];
          final digerListesi = digerListesiRaw.where((da) {
            final aciklama = (da['aciklama'] ?? '').toString().trim();
            final tutar = _toDouble(da['tutar']);
            return aciklama.isNotEmpty || tutar > 0;
          }).toList();
          if (digerListesi.isEmpty) return const SizedBox.shrink();
          final toplam =
              digerListesi.fold(0.0, (s, t) => s + _toDouble(t['tutar']));
          return _bolum(
            renk: Colors.grey[700]!,
            ikon: Icons.shopping_bag_outlined,
            baslik: 'DİĞER ALIMLAR',
            toplam: _fmt(toplam),
            child: Column(
                children: digerListesi
                    .where((t) => (t['tutar'] ?? 0) != 0)
                    .map((t) => _kalemSatiri(
                        t['aciklama'] ?? '', _fmt(_toDouble(t['tutar']))))
                    .toList()),
          );
        }),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _bolum(
      {required Color renk,
      required IconData ikon,
      required String baslik,
      String? toplam,
      required Widget child,
      bool hideBody = false}) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: renk.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ]),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
              color: renk,
              borderRadius: hideBody
                  ? BorderRadius.circular(14)
                  : const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(14))),
          child: Row(children: [
            Icon(ikon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(baslik,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1)),
            const Spacer(),
            if (toplam != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(toplam,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
              ),
          ]),
        ),
        if (!hideBody) Padding(padding: const EdgeInsets.all(14), child: child),
      ]),
    );
  }

  Widget _kalemSatiriRenk(String label, String deger, Color renk) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: TextStyle(color: renk, fontSize: 14)),
          Text(deger,
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: renk, fontSize: 14)),
        ]),
      );

  Widget _kalemSatiri(String label, String deger) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label,
              style: const TextStyle(color: Colors.black54, fontSize: 14)),
          Text(deger,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ]),
      );

  Widget _kalemSatiriBold(String label, String deger, {Color? renk}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          Text(deger,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: renk ?? Colors.black87)),
        ]),
      );

  Widget _kalemSatiriAlt(String label, String deger, Color renk) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: TextStyle(color: renk, fontSize: 13)),
          Text(deger,
              style: TextStyle(
                  color: renk, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      );

  Widget _kalemSatiriFark(String label, double fark) {
    Color renk = fark >= 0 ? Colors.green[700]! : Colors.red[700]!;
    String ikon = fark >= 0 ? '▲' : '▼';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label,
            style: const TextStyle(color: Colors.black54, fontSize: 14)),
        Text('$ikon ${fark.abs().toStringAsFixed(2)}',
            style: TextStyle(
                fontWeight: FontWeight.w600, color: renk, fontSize: 14)),
      ]),
    );
  }
}
