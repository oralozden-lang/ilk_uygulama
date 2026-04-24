import '../widgets/projeksiyon_widget.dart';
import '../widgets/gerceklesen_widget.dart';
import '../widgets/pos_kiyaslama_widget.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';

import '../core/kullanici_yetki.dart';
import 'giris_ekrani.dart';
import 'on_hazirlik_ekrani.dart';
import 'yonetici/subeler_tab.dart';
import 'yonetici/kullanicilar_tab.dart';
import 'yonetici/roller_tab.dart';
import 'yonetici/aktivite_tab.dart';
import 'yonetici/ayarlar_tab.dart';
import 'yonetici/raporlar_tab.dart';

// ─── Yönetici Paneli ──────────────────────────────────────────────────────────

class YoneticiPaneliEkrani extends StatefulWidget {
  final String kullanici;
  final KullaniciYetki yetki;
  const YoneticiPaneliEkrani({
    super.key,
    required this.kullanici,
    this.yetki = KullaniciYetki.yonetici,
  });

  @override
  State<YoneticiPaneliEkrani> createState() => _YoneticiPaneliEkraniState();
}

class _YoneticiPaneliEkraniState extends State<YoneticiPaneliEkrani>
    with WidgetsBindingObserver {
  Timer? _arkaPlanTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _arkaPlanTimer?.cancel();
      _arkaPlanTimer = Timer(const Duration(minutes: 20), () {
        if (mounted) _oturumZamanAsimiYonetici();
      });
    } else if (state == AppLifecycleState.resumed) {
      _arkaPlanTimer?.cancel();
      _arkaPlanTimer = null;
    }
  }

  Future<void> _oturumZamanAsimiYonetici() async {
    if (!mounted) return;
    final devamEt = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.timer_off, color: Colors.orange),
            SizedBox(width: 8),
            Text('Oturum Zaman Aşımı'),
          ],
        ),
        content: const Text(
          'Uygulama 20 dakikadır arka planda.\nDevam etmek istiyor musunuz?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Çıkış Yap', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0288D1),
              foregroundColor: Colors.white,
            ),
            child: const Text('Devam Et'),
          ),
        ],
      ),
    );
    if (devamEt == false) _cikisYap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _arkaPlanTimer?.cancel();
    super.dispose();
  }

  Future<void> _cikisYap() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const GirisEkrani()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = widget.yetki;

    final tabs = <Tab>[];
    final tabViews = <Widget>[];

    if (y.subeEkle) {
      tabs.add(const Tab(icon: Icon(Icons.store), text: 'Şubeler'));
      tabViews.add(const SubelerTab());
    }
    if (y.kullaniciEkle) {
      tabs.add(const Tab(icon: Icon(Icons.people), text: 'Kullanıcılar'));
      tabViews.add(const KullanicilarTab());
    }
    if (y.raporGoruntuleme) {
      tabs.add(const Tab(icon: Icon(Icons.bar_chart), text: 'Raporlar'));
      tabViews.add(RaporlarTab(merkziGiderGor: y.merkziGiderGor));
    }
    if (y.analizGor) {
      tabs.add(const Tab(icon: Icon(Icons.analytics), text: 'Analiz'));
      tabViews.add(_analizTab());
    }
    if (y.ayarlar) {
      tabs.add(const Tab(icon: Icon(Icons.settings), text: 'Ayarlar'));
      tabViews.add(const AyarlarTab());
    }
    if (y == KullaniciYetki.yonetici) {
      tabs.add(
          const Tab(icon: Icon(Icons.admin_panel_settings), text: 'Roller'));
      tabViews.add(const RollerTab());
    }
    if (y == KullaniciYetki.yonetici) {
      tabs.add(const Tab(icon: Icon(Icons.history), text: 'Aktivite'));
      tabViews.add(const AktiviteTab());
    }

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFF01579B),
                  Color(0xFF0288D1),
                  Color(0xFF29B6F6)
                ],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
          title: Text('${y.rolAdi ?? 'Yönetici'} Paneli'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Çıkış',
              onPressed: _cikisYap,
            ),
          ],
          bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            indicatorColor: Colors.white,
            isScrollable: true,
            tabs: tabs,
          ),
        ),
        body: TabBarView(children: tabViews),
      ),
    );
  }

  Widget _analizTab() {
    return FutureBuilder<List<String>>(
      future: FirebaseFirestore.instance
          .collection('subeler')
          .get()
          .then((snap) => snap.docs.map((d) => d.id).toList()),
      builder: (context, snap) {
        final subeler = snap.data ?? [];
        return DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Container(
                color: const Color(0xFF0288D1),
                child: const TabBar(
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white60,
                  indicatorColor: Colors.white,
                  indicatorWeight: 3,
                  tabs: [
                    Tab(
                        icon: Icon(Icons.trending_up, size: 18),
                        text: 'Tahmin'),
                    Tab(
                        icon: Icon(Icons.check_circle_outline, size: 18),
                        text: 'Gerçekleşen'),
                    Tab(
                        icon: Icon(Icons.compare_arrows, size: 18),
                        text: 'POS Kıyaslama'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    const ProjeksiyonWidget(key: ValueKey('tahmin')),
                    const GerceklesenWidget(),
                    PosKiyaslamaWidget(subeler: subeler),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
