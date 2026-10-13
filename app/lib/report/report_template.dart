import 'dart:math' as math;

import 'package:flutter/material.dart';

class ReportScene {
  const ReportScene(this.id, this.name, this.asset, {this.region = '通用'});

  final String id;
  final String name;
  final String asset;
  final String region;
}

const reportScenes = <ReportScene>[
  ReportScene(
    'vienna-stephansdom',
    '晨光',
    'assets/report_scenes/scene-01.jpg',
    region: '通用',
  ),
  ReportScene(
    'vienna-schonbrunn',
    '远山',
    'assets/report_scenes/scene-02.jpg',
    region: '通用',
  ),
  ReportScene(
    'vienna-khm',
    '湖畔',
    'assets/report_scenes/scene-03.jpg',
    region: '通用',
  ),
  ReportScene(
    'vienna-belvedere',
    '晚霞',
    'assets/report_scenes/scene-04.jpg',
    region: '通用',
  ),
  ReportScene(
    'melk-abbey',
    '林间',
    'assets/report_scenes/scene-05.jpg',
    region: '通用',
  ),
  ReportScene(
    'gmunden-lake',
    '海湾',
    'assets/report_scenes/scene-06.jpg',
    region: '通用',
  ),
  ReportScene(
    'st-wolfgang',
    '山谷',
    'assets/report_scenes/scene-07.jpg',
    region: '通用',
  ),
  ReportScene(
    'hallstatt',
    '秋色',
    'assets/report_scenes/scene-08.jpg',
    region: '通用',
  ),
  ReportScene(
    'gosau-three-lakes',
    '晴空',
    'assets/report_scenes/scene-09.jpg',
    region: '通用',
  ),
  ReportScene(
    'budapest-danube-night',
    '暮色',
    'assets/report_scenes/scene-10.jpg',
    region: '通用',
  ),
  ReportScene(
    'vienna-hofburg',
    '原野',
    'assets/report_scenes/scene-11.jpg',
    region: '通用',
  ),
  ReportScene(
    'vienna-karlskirche',
    '海风',
    'assets/report_scenes/scene-12.jpg',
    region: '通用',
  ),
  ReportScene(
    'vienna-hundertwasser',
    '山脊',
    'assets/report_scenes/scene-13.jpg',
    region: '通用',
  ),
  ReportScene(
    'vienna-prater',
    '清晨',
    'assets/report_scenes/scene-14.jpg',
    region: '通用',
  ),
  ReportScene(
    'schafberg-railway',
    '薄雾',
    'assets/report_scenes/scene-15.jpg',
    region: '通用',
  ),
  ReportScene(
    'bad-ischl',
    '沙丘',
    'assets/report_scenes/scene-16.jpg',
    region: '通用',
  ),
  ReportScene(
    'gosausee',
    '碧水',
    'assets/report_scenes/scene-17.jpg',
    region: '通用',
  ),
  ReportScene(
    'budapest-fishermans-bastion',
    '落日',
    'assets/report_scenes/scene-18.jpg',
    region: '通用',
  ),
  ReportScene(
    'budapest-parliament',
    '微光',
    'assets/report_scenes/scene-19.jpg',
    region: '通用',
  ),
  ReportScene(
    'budapest-chain-bridge-castle',
    '归途',
    'assets/report_scenes/scene-20.jpg',
    region: '通用',
  ),
];

ReportScene reportSceneById(String? id) => reportScenes.firstWhere(
  (scene) => scene.id == id,
  orElse: () => reportScenes.first,
);

class ReportPhotoSlot {
  const ReportPhotoSlot(this.rect, {this.degrees = 0, this.layer = 0});

  final Rect rect;
  final double degrees;
  final int layer;

  double get radians => degrees * math.pi / 180;
}

class ReportLayout {
  const ReportLayout(this.id, this.name, this.slots);

  final String id;
  final String name;
  final List<ReportPhotoSlot> slots;
}

const reportLayouts = <ReportLayout>[
  ReportLayout('left-main', '左主右三', [
    ReportPhotoSlot(Rect.fromLTWH(38, 230, 590, 555), degrees: -2.6, layer: 2),
    ReportPhotoSlot(Rect.fromLTWH(625, 155, 415, 305), degrees: 3.2, layer: 1),
    ReportPhotoSlot(Rect.fromLTWH(620, 470, 202, 290), degrees: -1.5, layer: 3),
    ReportPhotoSlot(Rect.fromLTWH(830, 486, 205, 275), degrees: 3.5, layer: 4),
  ]),
  ReportLayout('banner-three', '横幅三联', [
    ReportPhotoSlot(Rect.fromLTWH(40, 205, 1000, 360), degrees: -1.2, layer: 1),
    ReportPhotoSlot(Rect.fromLTWH(38, 560, 318, 250), degrees: 1.5, layer: 2),
    ReportPhotoSlot(Rect.fromLTWH(380, 555, 318, 255), degrees: -1.0, layer: 3),
    ReportPhotoSlot(Rect.fromLTWH(720, 560, 320, 245), degrees: 1.4, layer: 4),
  ]),
  ReportLayout('center-portrait', '中央竖主图', [
    ReportPhotoSlot(Rect.fromLTWH(300, 175, 490, 625), degrees: 0.5, layer: 3),
    ReportPhotoSlot(Rect.fromLTWH(35, 430, 260, 325), degrees: -4, layer: 1),
    ReportPhotoSlot(Rect.fromLTWH(705, 135, 340, 260), degrees: 4, layer: 2),
    ReportPhotoSlot(Rect.fromLTWH(790, 455, 255, 300), degrees: 3, layer: 4),
  ]),
  ReportLayout('right-main', '右主错落', [
    ReportPhotoSlot(Rect.fromLTWH(420, 285, 620, 500), degrees: 2.1, layer: 3),
    ReportPhotoSlot(Rect.fromLTWH(35, 245, 350, 410), degrees: -3.2, layer: 1),
    ReportPhotoSlot(Rect.fromLTWH(670, 120, 365, 255), degrees: 3.8, layer: 2),
    ReportPhotoSlot(Rect.fromLTWH(85, 590, 340, 220), degrees: -1.5, layer: 4),
  ]),
  ReportLayout('dual-main', '双主图', [
    ReportPhotoSlot(Rect.fromLTWH(35, 230, 490, 455), degrees: -2.6, layer: 1),
    ReportPhotoSlot(Rect.fromLTWH(555, 180, 490, 450), degrees: 3.0, layer: 2),
    ReportPhotoSlot(Rect.fromLTWH(310, 615, 300, 195), degrees: -1.8, layer: 3),
    ReportPhotoSlot(Rect.fromLTWH(640, 620, 330, 190), degrees: 1.5, layer: 4),
  ]),
  ReportLayout('banner-split', '横幅错分', [
    ReportPhotoSlot(Rect.fromLTWH(35, 200, 1010, 325), degrees: -1, layer: 1),
    ReportPhotoSlot(Rect.fromLTWH(35, 515, 545, 295), degrees: 0.8, layer: 2),
    ReportPhotoSlot(Rect.fromLTWH(595, 520, 450, 135), degrees: -0.8, layer: 3),
    ReportPhotoSlot(Rect.fromLTWH(595, 665, 450, 145), degrees: 0.7, layer: 4),
  ]),
  ReportLayout('right-portrait', '右竖左三', [
    ReportPhotoSlot(Rect.fromLTWH(620, 150, 420, 635), degrees: 3, layer: 3),
    ReportPhotoSlot(Rect.fromLTWH(35, 250, 560, 335), degrees: -2.8, layer: 1),
    ReportPhotoSlot(Rect.fromLTWH(35, 585, 270, 220), degrees: 1.2, layer: 2),
    ReportPhotoSlot(Rect.fromLTWH(320, 590, 280, 215), degrees: -1.2, layer: 4),
  ]),
];
