import '../core/formatters.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// ─── Ödeme Yöntemleri Kartı ──────────────────────────────────────────────────

class OdemeYontemleriKart extends StatefulWidget {
  const OdemeYontemleriKart();

  @override
  State<OdemeYontemleriKart> createState() => OdemeYontemleriKartState();
}

class OdemeYontemleriKartState extends State<OdemeYontemleriKart> {
  static const _koleksiyon = 'odemeyontemleri';

  List<Map<String, dynamic>> _liste = [];
  bool _yukleniyor = true;
  bool _migrasyonYapiliyor = false;

  @override
  void initState() {
    super.initState();
    _yukle();
  }

  Future<void> _yukle() async {
    setState(() => _yukleniyor = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection(_koleksiyon)
          .orderBy('sira')
          .get();
      if (mounted) {
        setState(() {
          _liste = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
          _yukleniyor = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  // ── Tek seferlik migrasyon — dogruKaynak ekle, pulseSira → sira ──────────
  Future<void> _migrasyonCalistir() async {
    final onay = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Veri Güncelleme'),
        content:
            const Text('Tüm ödeme yöntemlerine dogruKaynak alanı eklenecek.\n'
                'Bu işlem bir kez yapılmalıdır. Devam edilsin mi?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('İptal')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Güncelle')),
        ],
      ),
    );
    if (onay != true) return;

    setState(() => _migrasyonYapiliyor = true);
    try {
      final snap =
          await FirebaseFirestore.instance.collection(_koleksiyon).get();

      for (final doc in snap.docs) {
        final data = doc.data();
        final tip = data['tip'] as String? ?? 'yemekKarti';
        final guncellemeler = <String, dynamic>{};

        // dogruKaynak yoksa ekle
        if (!data.containsKey('dogruKaynak')) {
          guncellemeler['dogruKaynak'] = tip == 'online'
              ? 'myDominos'
              : tip == 'pulseKalemi'
                  ? 'pulse'
                  : 'program';
        }

        // sira yoksa pulseSira'dan al
        if (!data.containsKey('sira') && data.containsKey('pulseSira')) {
          guncellemeler['sira'] = data['pulseSira'];
        }

        if (guncellemeler.isNotEmpty) {
          await doc.reference.update(guncellemeler);
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ Güncelleme tamamlandı'),
            backgroundColor: Colors.green,
          ),
        );
        await _yukle();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Hata: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    if (mounted) setState(() => _migrasyonYapiliyor = false);
  }

  Future<void> _ekleDialog({Map<String, dynamic>? mevcut}) async {
    final adCtrl = TextEditingController(text: mevcut?['ad'] ?? '');
    final pulseCtrl = TextEditingController(text: mevcut?['pulseAdi'] ?? '');
    final digerCtrl =
        TextEditingController(text: mevcut?['digerEkranAdi'] ?? '');
    // sira: eski kayıtlarda pulseSira olabilir
    final mevcutSira = mevcut?['sira'] ?? mevcut?['pulseSira'];
    final siraCtrl = TextEditingController(
        text: mevcutSira != null ? mevcutSira.toString() : '');
    String tip = mevcut?['tip'] ?? 'yemekKarti';
    String dogruKaynak = mevcut?['dogruKaynak'] ?? _onerilenKaynak(tip);
    bool aktif = mevcut?['aktif'] ?? true;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(mevcut == null ? 'Yeni Ödeme Yöntemi' : 'Düzenle'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Ad
                TextFormField(
                  controller: adCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Ad *', isDense: true),
                  inputFormatters: [IlkHarfBuyukFormatter()],
                ),
                const SizedBox(height: 10),
                // Pulse adı
                TextFormField(
                  controller: pulseCtrl,
                  decoration: const InputDecoration(
                      labelText: "Pulse'daki adı (eşleştirme için)",
                      isDense: true),
                ),
                const SizedBox(height: 10),
                // MyDominos adı
                TextFormField(
                  controller: digerCtrl,
                  decoration: const InputDecoration(
                      labelText: 'MyDominos / Diğer ekrandaki adı',
                      isDense: true),
                ),
                const SizedBox(height: 10),
                // Sıra
                TextFormField(
                  controller: siraCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Sıra no (Pulse sırası ile aynı tutun)',
                      isDense: true),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 14),

                // Tip — bilgi amaçlı
                const Text('Tip',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                ...{
                  'yemekKarti': 'Yemek Kartı',
                  'online': 'Online',
                  'pulseKalemi': 'Pulse Kalemi',
                }.entries.map((e) => RadioListTile<String>(
                      title:
                          Text(e.value, style: const TextStyle(fontSize: 13)),
                      value: e.key,
                      groupValue: tip,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (v) => setDlg(() {
                        tip = v!;
                        dogruKaynak = _onerilenKaynak(v);
                      }),
                    )),
                const SizedBox(height: 14),

                // Doğru Kaynak — veri mantığı
                const Text('Doğru Veri Kaynağı',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const Text('Eşitlemede hangi kaynak geçerli kabul edilsin?',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 4),
                ...{
                  'program': 'Program (Yemek kartı programı)',
                  'myDominos': 'MyDominos',
                  'pulse': 'Pulse',
                }.entries.map((e) => RadioListTile<String>(
                      title:
                          Text(e.value, style: const TextStyle(fontSize: 13)),
                      value: e.key,
                      groupValue: dogruKaynak,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (v) => setDlg(() => dogruKaynak = v!),
                    )),
                const SizedBox(height: 8),

                // Aktif
                SwitchListTile(
                  title: const Text('Aktif', style: TextStyle(fontSize: 13)),
                  value: aktif,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setDlg(() => aktif = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('İptal', style: TextStyle(color: Colors.red)),
            ),
            FilledButton(
              onPressed: () async {
                final ad = adCtrl.text.trim();
                if (ad.isEmpty) return;
                final veri = {
                  'ad': ad,
                  'tip': tip,
                  'dogruKaynak': dogruKaynak,
                  'pulseAdi': pulseCtrl.text.trim(),
                  'digerEkranAdi': digerCtrl.text.trim(),
                  'sira': int.tryParse(siraCtrl.text.trim()) ?? 99,
                  'aktif': aktif,
                };
                if (mevcut != null) {
                  await FirebaseFirestore.instance
                      .collection(_koleksiyon)
                      .doc(mevcut['id'] as String)
                      .update(veri);
                } else {
                  await FirebaseFirestore.instance
                      .collection(_koleksiyon)
                      .add(veri);
                }
                if (ctx.mounted) Navigator.pop(ctx);
                await _yukle();
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
    adCtrl.dispose();
    pulseCtrl.dispose();
    digerCtrl.dispose();
    siraCtrl.dispose();
  }

  String _onerilenKaynak(String tip) {
    if (tip == 'online') return 'myDominos';
    if (tip == 'pulseKalemi') return 'pulse';
    return 'program';
  }

  Future<void> _sil(String id) async {
    final onay = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sil'),
        content: const Text('Bu ödeme yöntemi silinecek. Emin misiniz?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('İptal')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sil')),
        ],
      ),
    );
    if (onay == true) {
      await FirebaseFirestore.instance.collection(_koleksiyon).doc(id).delete();
      await _yukle();
    }
  }

  Widget _etiket(String yazi, Color renk) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: renk.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(yazi,
            style: TextStyle(
                fontSize: 10, color: renk, fontWeight: FontWeight.w600)),
      );

  @override
  Widget build(BuildContext context) {
    // dogruKaynak alanı eksik olan kayıt var mı
    final migrasyonGerekli =
        _liste.any((item) => !item.containsKey('dogruKaynak'));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ödeme Yöntemleri',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      SizedBox(height: 4),
                      Text('Yemek kartları, online ve Pulse kalemleri.',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _ekleDialog(),
                  icon: const Icon(Icons.add_circle_outline,
                      color: Color(0xFF0288D1)),
                  tooltip: 'Yeni ekle',
                ),
              ],
            ),

            // Migrasyon uyarısı — dogruKaynak eksikse göster
            if (migrasyonGerekli)
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange[300]!),
                ),
                child: Row(children: [
                  Icon(Icons.update, color: Colors.orange[700], size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Veri güncelleme gerekiyor (dogruKaynak alanı eksik)',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _migrasyonYapiliyor
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(
                          onPressed: _migrasyonCalistir,
                          child: const Text('Güncelle',
                              style: TextStyle(fontSize: 12)),
                        ),
                ]),
              ),

            const SizedBox(height: 8),
            if (_yukleniyor)
              const Center(child: CircularProgressIndicator())
            else if (_liste.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Henüz ödeme yöntemi eklenmemiş.',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                  ),
                ),
              )
            else
              ..._liste.map((item) {
                final ad = item['ad'] as String? ?? '';
                final tip = item['tip'] as String? ?? 'yemekKarti';
                final dogruKaynak = item['dogruKaynak'] as String? ?? '';
                final aktif = item['aktif'] as bool? ?? true;
                final pulseAdi = item['pulseAdi'] as String? ?? '';
                final digerAdi = item['digerEkranAdi'] as String? ?? '';
                final sira = item['sira'] ?? item['pulseSira'] ?? '—';

                final tipRenk = tip == 'online'
                    ? const Color(0xFF0288D1)
                    : tip == 'pulseKalemi'
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFF6A1B9A);
                final tipYazi = tip == 'online'
                    ? 'Online'
                    : tip == 'pulseKalemi'
                        ? 'Pulse Kalemi'
                        : 'Yemek Kartı';

                final kaynakRenk = dogruKaynak == 'myDominos'
                    ? const Color(0xFF0288D1)
                    : dogruKaynak == 'pulse'
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFF6A1B9A);
                final kaynakYazi = dogruKaynak == 'myDominos'
                    ? '✓ MyDominos'
                    : dogruKaynak == 'pulse'
                        ? '✓ Pulse'
                        : dogruKaynak == 'program'
                            ? '✓ Program'
                            : '';

                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: aktif
                        ? Colors.grey.withOpacity(0.06)
                        : Colors.grey.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      // Sıra no
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(6),
                        ),
                        alignment: Alignment.center,
                        child: Text('$sira',
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(ad,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: aktif ? null : Colors.grey)),
                            const SizedBox(height: 4),
                            Wrap(spacing: 4, runSpacing: 4, children: [
                              _etiket(tipYazi, tipRenk),
                              if (kaynakYazi.isNotEmpty)
                                _etiket(kaynakYazi, kaynakRenk),
                              if (!aktif) _etiket('Pasif', Colors.grey),
                            ]),
                            if (pulseAdi.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text('Pulse: $pulseAdi',
                                    style: TextStyle(
                                        fontSize: 11, color: Colors.grey[500])),
                              ),
                            if (digerAdi.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Text('MyDominos: $digerAdi',
                                    style: TextStyle(
                                        fontSize: 11, color: Colors.grey[500])),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined,
                            size: 18, color: Color(0xFF0288D1)),
                        onPressed: () => _ekleDialog(mevcut: item),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 18, color: Colors.redAccent),
                        onPressed: () => _sil(item['id'] as String),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
