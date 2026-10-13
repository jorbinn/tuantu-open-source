// Opt-in artifact rendering with labelled demo data. Outputs stay outside Git.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuantu_app/report/report_card.dart';
import 'package:tuantu_app/report/story_chapter.dart';
import 'package:tuantu_app/report/story_model.dart';

import '../test/fixtures/story_sample.dart';

void main() {
  testWidgets('render actual story chapters as preview artifacts', (
    tester,
  ) async {
    final out = Directory(Platform.environment['STORY_PREVIEW_DIR']!);
    final fontPath = Platform.environment['STORY_PREVIEW_FONT']!;
    final assets = ReportCardAssets(photos: {}, avatars: {});
    final raw = storySample();
    for (final member in raw['members'] as List) {
      member['avatar'] = 100 + (member['person_id'] as int);
    }
    for (final photographer in raw['person']['photographers'] as List) {
      photographer['avatar'] = 100 + (photographer['user_id'] as int);
    }
    raw['pool'] = [
      for (var id = 1; id <= 12; id++)
        {
          'id': id,
          'kind': 'image',
          'persons': [1, 2],
          'uploader_id': 12,
          'likes': id,
          'comments': 0,
          'taken_w': id * 1000,
        },
    ];
    final model = StoryModel(raw);
    await tester.runAsync(() async {
      out.createSync(recursive: true);
      final font = FontLoader('StoryPreview')
        ..addFont(
          File(fontPath).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      await font.load();
      final iconPath = Platform.environment['STORY_PREVIEW_ICON_FONT'];
      if (iconPath != null) {
        await (FontLoader('MaterialIcons')..addFont(
              File(iconPath).readAsBytes().then((b) => ByteData.sublistView(b)),
            ))
            .load();
      }
      for (var id = 1; id <= 12; id++) {
        final bytes = await rootBundle.load(
          'assets/report_scenes/scene-${id.toString().padLeft(2, '0')}.jpg',
        );
        final codec = await ui.instantiateImageCodec(
          bytes.buffer.asUint8List(),
          targetWidth: 600,
        );
        assets.photos[id] = (await codec.getNextFrame()).image;
        codec.dispose();
      }
      assets.avatars[model.selfPerson.cover!] = assets.photos[1]!;
      for (var i = 0; i < model.partners.length; i++) {
        final cover = model.partners[i].cover;
        if (cover != null) assets.avatars[cover] = assets.photos[i + 2]!;
      }
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final personal in [true, false]) {
      final chapters = model.chapters(personal);
      final boundary = GlobalKey();
      final sectionKeys = List.generate(chapters.length, (_) => GlobalKey());
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'StoryPreview'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: boundary,
                child: Column(
                  children: [
                    const ColoredBox(
                      color: storyPaper,
                      child: SizedBox(
                        width: double.infinity,
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            '效果预览 · 示例数据与示意图片',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: storyAccent, fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                    for (var i = 0; i < chapters.length; i++)
                      RepaintBoundary(
                        key: sectionKeys[i],
                        child: StoryChapterView(
                          chapter: chapters[i],
                          model: model,
                          assets: assets,
                          personal: personal,
                          index: i,
                          revealed: true,
                          exporting: true,
                          minHeight: 580,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${out.path}/${personal ? 'personal' : 'team'}-story.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
        for (final index in [0, 1, 2]) {
          final image =
              await (sectionKeys[index].currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${out.path}/${personal ? 'personal' : 'team'}-chapter-$index.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        }
      });
    }
    await tester.pumpWidget(const SizedBox());
    for (final image in assets.photos.values) {
      image.dispose();
    }
  });
}
