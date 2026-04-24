import 'package:excel/excel.dart' as xl;
import '../excel_download.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../core/utils.dart';
// ─── Şube Özet Tablosu ────────────────────────────────────────────────────────

class SubeOzetTablosu extends StatefulWidget {
  final List<String> subeler;
  const SubeOzetTablosu({this.subeler = const []});

  @override
  State<SubeOzetTablosu> createState() => SubeOzetTablosuState();
}

class SubeOzetTablosuState extends State<SubeOzetTablosu>
    with AutomaticKeepAliveClientMixin {
  String _filtreModu = 'ay';
  int _secilenYil = DateTime.now().year;
  int _secilenAy = DateTime.now().month;
  DateTime _baslangic = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _bitis = DateTime.now();

  bool _karsilastirmaAcik = false;
  int _karsilastirmaYil = DateTime.now().year;
  int _karsilastirmaAy =
      DateTime.now().month == 1 ? 12 : DateTime.now().month - 1;
  DateTime _karsilastirmaBaslangic = DateTime(
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month - 1,
    1,
  );
  DateTime _karsilastirmaBitis = DateTime(
    DateTime.now().year,
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month - 1 + 1,
    0,
  );

  bool _yukleniyor = false;
  Map<String, String> _subeAdlari = {};
  // subeId → {ciro, anaKasaTL, anaKasaUSD, anaKasaEUR, anaKasaGBP}
  List<Map<String, dynamic>> _subeVeriler = [];
  List<Map<String, dynamic>> _karsilastirmaVeriler = [];

  double _kdvOrani = 10.0; // Firestore'dan yüklenir

  final _aylar = [
    'Ocak',
    'Şubat',
    'Mart',
    'Nisan',
    'Mayıs',
    'Haziran',
    'Temmuz',
    'Ağustos',
    'Eylül',
    'Ekim',
    'Kasım',
    'Aralık',
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _subeAdlariniYukle();
    // Sayfa açılınca mevcut ay ile otomatik yükle
    WidgetsBinding.instance.addPostFrameCallback((_) => _yukle());
  }

  Future<void> _subeAdlariniYukle() async {
    final snap = await FirebaseFirestore.instance.collection('subeler').get();
    final adlar = <String, String>{};
    for (var doc in snap.docs) {
      adlar[doc.id] = (doc.data()['ad'] as String?) ?? doc.id;
    }
    if (mounted) setState(() => _subeAdlari = adlar);
  }

  List<String> get _aktifSubeler =>
      widget.subeler.isNotEmpty ? widget.subeler : _subeAdlari.keys.toList();

  String _tarihKey(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  String _baslangicKey() {
    if (_filtreModu == 'ay') {
      return '${_secilenYil.toString().padLeft(4, '0')}-${_secilenAy.toString().padLeft(2, '0')}-01';
    }
    return _tarihKey(_baslangic);
  }

  String _bitisKey() {
    if (_filtreModu == 'ay') {
      final sonGun = DateTime(_secilenYil, _secilenAy + 1, 0).day;
      return '${_secilenYil.toString().padLeft(4, '0')}-${_secilenAy.toString().padLeft(2, '0')}-${sonGun.toString().padLeft(2, '0')}';
    }
    return _tarihKey(_bitis);
  }

  String _karsilastirmaBasKey() {
    if (_filtreModu == 'ay') {
      return '${_karsilastirmaYil.toString().padLeft(4, '0')}-${_karsilastirmaAy.toString().padLeft(2, '0')}-01';
    }
    return _tarihKey(_karsilastirmaBaslangic);
  }

  String _karsilastirmaBitKey() {
    if (_filtreModu == 'ay') {
      final sonGun = DateTime(_karsilastirmaYil, _karsilastirmaAy + 1, 0).day;
      return '${_karsilastirmaYil.toString().padLeft(4, '0')}-${_karsilastirmaAy.toString().padLeft(2, '0')}-${sonGun.toString().padLeft(2, '0')}';
    }
    return _tarihKey(_karsilastirmaBitis);
  }

  Future<List<Map<String, dynamic>>> _veriCek(String bas, String bit) async {
    // Tüm şubeler paralel — sıralı await yerine Future.wait
    final futures = _aktifSubeler.map((subeId) async {
      final snap = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(subeId)
          .collection('gunluk')
          .where('tarih', isGreaterThanOrEqualTo: bas)
          .where('tarih', isLessThanOrEqualTo: bit)
          .orderBy('tarih')
          .get();

      double ciro = 0,
          anaKasaTL = 0,
          anaKasaUSD = 0,
          anaKasaEUR = 0,
          anaKasaGBP = 0;
      for (var doc in snap.docs) {
        final d = doc.data();
        ciro += ((d['gunlukSatisToplami'] as num?) ?? 0).toDouble();
      }
      // Ana Kasa: dönemin son gününün kalanı
      if (snap.docs.isNotEmpty) {
        final son = snap.docs.last.data();
        anaKasaTL = ((son['anaKasaKalani'] as num?) ?? 0).toDouble();
        final dovizKalanlar = son['dovizAnaKasaKalanlari'] as Map?;
        if (dovizKalanlar != null) {
          anaKasaUSD = ((dovizKalanlar['USD'] as num?) ?? 0).toDouble();
          anaKasaEUR = ((dovizKalanlar['EUR'] as num?) ?? 0).toDouble();
          anaKasaGBP = ((dovizKalanlar['GBP'] as num?) ?? 0).toDouble();
        }
      }
      return {
        'subeId': subeId,
        'subeAd': _subeAdlari[subeId] ?? subeId,
        'ciro': ciro,
        'anaKasaTL': anaKasaTL,
        'anaKasaUSD': anaKasaUSD,
        'anaKasaEUR': anaKasaEUR,
        'anaKasaGBP': anaKasaGBP,
      };
    });

    return List<Map<String, dynamic>>.from(await Future.wait(futures));
  }

  Future<void> _yukle() async {
    setState(() => _yukleniyor = true);
    try {
      // KDV oranını Firestore'dan yükle
      final ayarSnap = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .get();
      final kdvOrani =
          (ayarSnap.data()?['kdvOrani'] as num?)?.toDouble() ?? 10.0;

      final veriler = await _veriCek(_baslangicKey(), _bitisKey());
      // Ciro büyükten küçüğe sırala
      veriler.sort(
        (a, b) => (b['ciro'] as double).compareTo(a['ciro'] as double),
      );
      List<Map<String, dynamic>> karsilastirma = [];
      if (_karsilastirmaAcik) {
        karsilastirma = await _veriCek(
          _karsilastirmaBasKey(),
          _karsilastirmaBitKey(),
        );
      }
      if (mounted)
        setState(() {
          _subeVeriler = veriler;
          _karsilastirmaVeriler = karsilastirma;
          _kdvOrani = kdvOrani;
          _yukleniyor = false;
        });
    } catch (e) {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  String _fmt(double v) {
    if (v == 0) return '0,00 ₺';
    final neg = v < 0;
    final abs = v.abs();
    final parts = abs.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '${neg ? '-' : ''}${buf.toString()},${parts[1]} ₺';
  }

  String _fmtDoviz(double v, String sembol) {
    if (v == 0) return '';
    final parts = v.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '$sembol ${buf.toString()},${parts[1]}';
  }

  String _fmtYuzde(double yeni, double eski) {
    if (eski == 0) return '';
    final pct = ((yeni - eski) / eski * 100);
    final sign = pct >= 0 ? '▲' : '▼';
    return '$sign ${pct.abs().toStringAsFixed(1)}%';
  }

  double _karsilastirmaCiro(String subeId) {
    for (var v in _karsilastirmaVeriler) {
      if (v['subeId'] == subeId) return (v['ciro'] as double);
    }
    return 0;
  }

  Future<void> _excelIndir() async {
    if (_subeVeriler.isEmpty) return;
    try {
      final excel = xl.Excel.createExcel();
      excel.rename('Sheet1', 'Şube Özet');
      final sheet = excel['Şube Özet'];

      // Başlıklar
      final basliklar = ['Şube', 'Ciro', 'Ana Kasa (TL)', 'USD', 'EUR', 'GBP'];
      if (_karsilastirmaAcik) basliklar.addAll(['Önceki Ciro', 'Fark %']);
      for (int i = 0; i < basliklar.length; i++) {
        final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
        );
        cell.value = xl.TextCellValue(basliklar[i]);
        cell.cellStyle = xl.CellStyle(
          bold: true,
          backgroundColorHex: xl.ExcelColor.fromHexString('#0288D1'),
          fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        );
      }

      // Toplam satırı
      double toplamCiro = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['ciro'] as double),
      );
      double toplamTL = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['anaKasaTL'] as double),
      );
      double toplamUSD = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['anaKasaUSD'] as double),
      );
      double toplamEUR = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['anaKasaEUR'] as double),
      );
      double toplamGBP = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['anaKasaGBP'] as double),
      );

      final toplamRow = [
        xl.TextCellValue('GENEL TOPLAM'),
        xl.DoubleCellValue(toplamCiro),
        xl.DoubleCellValue(toplamTL),
        xl.DoubleCellValue(toplamUSD),
        xl.DoubleCellValue(toplamEUR),
        xl.DoubleCellValue(toplamGBP),
      ];
      for (int i = 0; i < toplamRow.length; i++) {
        final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 1),
        );
        cell.value = toplamRow[i];
        cell.cellStyle = xl.CellStyle(
          bold: true,
          backgroundColorHex: xl.ExcelColor.fromHexString('#E3F2FD'),
        );
      }

      // Şube satırları
      for (int r = 0; r < _subeVeriler.length; r++) {
        final v = _subeVeriler[r];
        final rowData = [
          xl.TextCellValue(v['subeAd'] as String),
          xl.DoubleCellValue(v['ciro'] as double),
          xl.DoubleCellValue(v['anaKasaTL'] as double),
          xl.DoubleCellValue(v['anaKasaUSD'] as double),
          xl.DoubleCellValue(v['anaKasaEUR'] as double),
          xl.DoubleCellValue(v['anaKasaGBP'] as double),
        ];
        if (_karsilastirmaAcik) {
          final onceki = _karsilastirmaCiro(v['subeId'] as String);
          rowData.add(xl.DoubleCellValue(onceki));
          final pct = onceki > 0
              ? ((v['ciro'] as double) - onceki) / onceki * 100
              : 0.0;
          rowData.add(xl.DoubleCellValue(pct));
        }
        for (int i = 0; i < rowData.length; i++) {
          sheet
              .cell(
                xl.CellIndex.indexByColumnRow(
                  columnIndex: i,
                  rowIndex: r + 2,
                ),
              )
              .value = rowData[i];
        }
      }

      final bytes = excel.save();
      if (bytes != null) {
        await excelKaydet(
          bytes,
          'sube_ozet_${_baslangicKey()}_${_bitisKey()}.xlsx',
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Excel hatası: $e'),
            backgroundColor: Colors.red,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final maxCiro = _subeVeriler.isEmpty
        ? 1.0
        : _subeVeriler
            .map((v) => v['ciro'] as double)
            .reduce((a, b) => a > b ? a : b)
            .clamp(1.0, double.infinity);

    final toplamCiro = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['ciro'] as double),
    );
    final toplamTL = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['anaKasaTL'] as double),
    );
    final toplamUSD = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['anaKasaUSD'] as double),
    );
    final toplamEUR = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['anaKasaEUR'] as double),
    );
    final toplamGBP = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['anaKasaGBP'] as double),
    );

    final oncekiToplamCiro = _karsilastirmaVeriler.fold(
      0.0,
      (s, v) => s + (v['ciro'] as double),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Filtre ───────────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'ay',
                        label: Text('Ay Seç'),
                        icon: Icon(Icons.calendar_month),
                      ),
                      ButtonSegment(
                        value: 'aralik',
                        label: Text('Tarih Aralığı'),
                        icon: Icon(Icons.date_range),
                      ),
                    ],
                    selected: {_filtreModu},
                    onSelectionChanged: (s) =>
                        setState(() => _filtreModu = s.first),
                  ),
                  const SizedBox(height: 12),
                  if (_filtreModu == 'ay') ...[
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _secilenAy,
                            decoration: const InputDecoration(
                              labelText: 'Ay',
                              border: OutlineInputBorder(),
                            ),
                            items: List.generate(
                              12,
                              (i) => DropdownMenuItem(
                                value: i + 1,
                                child: Text(_aylar[i]),
                              ),
                            ),
                            onChanged: (v) => setState(() => _secilenAy = v!),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _secilenYil,
                            decoration: const InputDecoration(
                              labelText: 'Yıl',
                              border: OutlineInputBorder(),
                            ),
                            items:
                                List.generate(5, (i) => DateTime.now().year - i)
                                    .map(
                                      (y) => DropdownMenuItem(
                                        value: y,
                                        child: Text('$y'),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (v) => setState(() => _secilenYil = v!),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final p = await showDatePicker(
                                context: context,
                                initialDate: _baslangic,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now(),
                              );
                              if (p != null) setState(() => _baslangic = p);
                            },
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              '${_baslangic.day.toString().padLeft(2, '0')}.${_baslangic.month.toString().padLeft(2, '0')}.${_baslangic.year}',
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('—'),
                        ),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final p = await showDatePicker(
                                context: context,
                                initialDate: _bitis,
                                firstDate: _baslangic,
                                lastDate: DateTime.now(),
                              );
                              if (p != null) setState(() => _bitis = p);
                            },
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              '${_bitis.day.toString().padLeft(2, '0')}.${_bitis.month.toString().padLeft(2, '0')}.${_bitis.year}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Önceki Dönemle Karşılaştır'),
                    value: _karsilastirmaAcik,
                    activeColor: const Color(0xFF0288D1),
                    onChanged: (v) {
                      setState(() {
                        _karsilastirmaAcik = v;
                        if (v) {
                          // Açılınca otomatik: bir önceki ay
                          final simdi = DateTime.now();
                          final oncekiAy =
                              simdi.month == 1 ? 12 : simdi.month - 1;
                          final oncekiYil =
                              simdi.month == 1 ? simdi.year - 1 : simdi.year;
                          _karsilastirmaAy = oncekiAy;
                          _karsilastirmaYil = oncekiYil;
                          _karsilastirmaBaslangic = DateTime(
                            oncekiYil,
                            oncekiAy,
                            1,
                          );
                          _karsilastirmaBitis = DateTime(
                            oncekiYil,
                            oncekiAy + 1,
                            0,
                          );
                          // Karşılaştırma modunu ana filtreden bağımsız başlat
                        }
                      });
                    },
                  ),
                  if (_karsilastirmaAcik) ...[
                    const SizedBox(height: 8),
                    if (_filtreModu == 'ay')
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _karsilastirmaAy,
                              decoration: const InputDecoration(
                                labelText: 'Karş. Ay',
                                border: OutlineInputBorder(),
                              ),
                              items: List.generate(
                                12,
                                (i) => DropdownMenuItem(
                                  value: i + 1,
                                  child: Text(_aylar[i]),
                                ),
                              ),
                              onChanged: (v) =>
                                  setState(() => _karsilastirmaAy = v!),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _karsilastirmaYil,
                              decoration: const InputDecoration(
                                labelText: 'Karş. Yıl',
                                border: OutlineInputBorder(),
                              ),
                              items: List.generate(
                                5,
                                (i) => DateTime.now().year - i,
                              )
                                  .map(
                                    (y) => DropdownMenuItem(
                                      value: y,
                                      child: Text('$y'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _karsilastirmaYil = v!),
                            ),
                          ),
                        ],
                      ),
                    if (_filtreModu == 'aralik')
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final p = await showDatePicker(
                                  context: context,
                                  initialDate: _karsilastirmaBaslangic,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime.now(),
                                );
                                if (p != null)
                                  setState(() => _karsilastirmaBaslangic = p);
                              },
                              icon: const Icon(Icons.calendar_today, size: 16),
                              label: Text(
                                '${_karsilastirmaBaslangic.day.toString().padLeft(2, '0')}.${_karsilastirmaBaslangic.month.toString().padLeft(2, '0')}.${_karsilastirmaBaslangic.year}',
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('—'),
                          ),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final p = await showDatePicker(
                                  context: context,
                                  initialDate: _karsilastirmaBitis,
                                  firstDate: _karsilastirmaBaslangic,
                                  lastDate: DateTime.now(),
                                );
                                if (p != null)
                                  setState(() => _karsilastirmaBitis = p);
                              },
                              icon: const Icon(Icons.calendar_today, size: 16),
                              label: Text(
                                '${_karsilastirmaBitis.day.toString().padLeft(2, '0')}.${_karsilastirmaBitis.month.toString().padLeft(2, '0')}.${_karsilastirmaBitis.year}',
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _yukle,
                          icon: _yukleniyor
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.search),
                          label: const Text('Raporu Getir'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0288D1),
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      if (_subeVeriler.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _excelIndir,
                          icon: const Icon(Icons.table_chart, size: 18),
                          label: const Text('Excel'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.green[700],
                            side: BorderSide(color: Colors.green[700]!),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),

          if (_subeVeriler.isNotEmpty) ...[
            const SizedBox(height: 16),

            // ── CİRO BÖLÜMÜ ─────────────────────────────────────────────
            const Text(
              'Ciro Sıralaması',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.black54,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            // Ciro kartı — şube adı + bar sabit, sağa scroll ile KDVsiz görünür
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0288D1).withOpacity(0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // ── HEADER ──────────────────────────────────────────────
                    Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFF0288D1),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(14),
                          topRight: Radius.circular(14),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Text(
                              'Genel Toplam Ciro',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 10,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_karsilastirmaAcik &&
                                        oncekiToplamCiro > 0) ...[
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            'Önceki: ${_fmt(oncekiToplamCiro)}',
                                            style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 10,
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withOpacity(
                                                0.15,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                            child: Text(
                                              _fmtYuzde(
                                                toplamCiro,
                                                oncekiToplamCiro,
                                              ),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: toplamCiro >=
                                                        oncekiToplamCiro
                                                    ? Colors.greenAccent
                                                    : Colors.redAccent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(width: 10),
                                    ],
                                    Text(
                                      _fmt(toplamCiro),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (toplamCiro > 0) ...[
                                      const SizedBox(width: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: Colors.white.withOpacity(
                                              0.3,
                                            ),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              'KDVsiz (%${_kdvOrani.toStringAsFixed(0)})',
                                              style: TextStyle(
                                                color: Colors.white.withOpacity(
                                                  0.7,
                                                ),
                                                fontSize: 9,
                                              ),
                                            ),
                                            Text(
                                              _fmt(
                                                toplamCiro /
                                                    (1 + _kdvOrani / 100),
                                              ),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ── ŞUBE SATIRLARI ──────────────────────────────────────
                    ..._subeVeriler.asMap().entries.map((entry) {
                      final i = entry.key;
                      final v = entry.value;
                      final ciro = v['ciro'] as double;
                      final oncekiCiro = _karsilastirmaAcik
                          ? _karsilastirmaCiro(v['subeId'] as String)
                          : 0.0;
                      final barOran = maxCiro > 0 ? ciro / maxCiro : 0.0;
                      final oncekiBarOran =
                          maxCiro > 0 ? oncekiCiro / maxCiro : 0.0;
                      final rankColors = [
                        [const Color(0xFFFFF8E1), const Color(0xFFF57F17)],
                        [const Color(0xFFECEFF1), const Color(0xFF455A64)],
                        [const Color(0xFFFBE9E7), const Color(0xFFBF360C)],
                      ];
                      final rankColor = i < 3
                          ? rankColors[i]
                          : [Colors.grey[100]!, Colors.grey[600]!];
                      return Container(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.grey.withOpacity(0.12),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            // SABİT SOL: sıra no + şube adı + bar
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: rankColor[0],
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Text(
                                          '${i + 1}',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: rankColor[1],
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            v['subeAd'] as String,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                            child: LinearProgressIndicator(
                                              value: barOran,
                                              backgroundColor: Colors.grey[100],
                                              valueColor:
                                                  const AlwaysStoppedAnimation<
                                                      Color>(Color(0xFF0288D1)),
                                              minHeight: 5,
                                            ),
                                          ),
                                          if (_karsilastirmaAcik &&
                                              oncekiCiro > 0) ...[
                                            const SizedBox(height: 2),
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                              child: LinearProgressIndicator(
                                                value: oncekiBarOran,
                                                backgroundColor:
                                                    Colors.grey[100],
                                                valueColor:
                                                    const AlwaysStoppedAnimation<
                                                            Color>(
                                                        Color(0xFF90A4AE)),
                                                minHeight: 3,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // SCROLL SAĞ: ciro + KDVsiz
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          _fmt(ciro),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (_karsilastirmaAcik &&
                                            oncekiCiro > 0) ...[
                                          const SizedBox(height: 2),
                                          Builder(
                                            builder: (_) {
                                              final yuzde = _fmtYuzde(
                                                ciro,
                                                oncekiCiro,
                                              );
                                              final artis = ciro >= oncekiCiro;
                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 4,
                                                      vertical: 1,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: artis
                                                          ? Colors.green[50]
                                                          : Colors.red[50],
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        3,
                                                      ),
                                                    ),
                                                    child: Text(
                                                      yuzde,
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: artis
                                                            ? Colors.green[700]
                                                            : Colors.red[700],
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    _fmt(oncekiCiro),
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color:
                                                          Colors.blueGrey[600],
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (ciro > 0) ...[
                                      const SizedBox(width: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF0288D1,
                                          ).withOpacity(0.07),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: const Color(
                                              0xFF0288D1,
                                            ).withOpacity(0.18),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              'KDVsiz',
                                              style: TextStyle(
                                                color: Colors.grey[600],
                                                fontSize: 9,
                                              ),
                                            ),
                                            Text(
                                              _fmt(
                                                ciro / (1 + _kdvOrani / 100),
                                              ),
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF0288D1),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── ANA KASA BÖLÜMÜ ──────────────────────────────────────────
            const Text(
              'Ana Kasa Kalanları',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.black54,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1565C0).withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Toplam şerit
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1565C0),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(14),
                        topRight: Radius.circular(14),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Flexible(
                          child: Text(
                            'Genel Toplam Ana Kasa',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              if (toplamUSD != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF8E1),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    '\$ ${toplamUSD.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      color: Color(0xFFE65100),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (toplamEUR != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3E5F5),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    '€ ${toplamEUR.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      color: Color(0xFF6A1B9A),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (toplamGBP != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE8F5E9),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    '£ ${toplamGBP.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      color: Color(0xFF1B5E20),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              Text(
                                _fmt(toplamTL),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Şube satırları
                  ..._subeVeriler.map((v) {
                    final tl = v['anaKasaTL'] as double;
                    final usd = v['anaKasaUSD'] as double;
                    final eur = v['anaKasaEUR'] as double;
                    final gbp = v['anaKasaGBP'] as double;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Colors.grey.withOpacity(0.12),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              v['subeAd'] as String,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Wrap(
                            spacing: 6,
                            alignment: WrapAlignment.end,
                            children: [
                              if (usd != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF8E1),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    _fmtDoviz(usd, '\$'),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFFE65100),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (eur != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3E5F5),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    _fmtDoviz(eur, '€'),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF6A1B9A),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (gbp != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE8F5E9),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    _fmtDoviz(gbp, '£'),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF1B5E20),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              Text(
                                _fmt(tl),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: tl >= 0
                                      ? const Color(0xFF0C447C)
                                      : Colors.red[700]!,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ],
      ),
    );
  }
}
