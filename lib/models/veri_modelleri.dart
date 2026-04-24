import 'package:flutter/material.dart';

// ─── Veri Modelleri ───────────────────────────────────────────────────────────

class PosGirisi {
  TextEditingController adCtrl;
  TextEditingController tutarCtrl;
  bool yeni;

  PosGirisi({String ad = '', String tutar = '', this.yeni = false})
      : adCtrl = TextEditingController(text: ad),
        tutarCtrl = TextEditingController(text: tutar);

  String get ad => adCtrl.text;
  String get tutar => tutarCtrl.text;

  void dispose() {
    adCtrl.dispose();
    tutarCtrl.dispose();
  }
}

class YemekKartiGirisi {
  String cins;
  TextEditingController tutarCtrl;
  bool yeni;

  YemekKartiGirisi({this.cins = '', String tutar = '', this.yeni = false})
      : tutarCtrl = TextEditingController(text: tutar);

  void dispose() {
    tutarCtrl.dispose();
  }
}

class HarcamaGirisi {
  TextEditingController aciklamaCtrl;
  TextEditingController tutarCtrl;
  bool yeni;

  HarcamaGirisi({String aciklama = '', String tutar = '', this.yeni = false})
      : aciklamaCtrl = TextEditingController(text: aciklama),
        tutarCtrl = TextEditingController(text: tutar);

  String get aciklama => aciklamaCtrl.text;
  String get tutar => tutarCtrl.text;

  void dispose() {
    aciklamaCtrl.dispose();
    tutarCtrl.dispose();
  }
}
