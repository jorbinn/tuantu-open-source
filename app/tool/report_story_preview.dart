/// Offline UI preview only: flutter run -t tool/report_story_preview.dart
/// Uses explicitly labelled example data; never writes to a box or claims a face.
library;

import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tuantu_app/api.dart';
import 'package:tuantu_app/pages/report_list_page.dart';
import '../test/fixtures/story_sample.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final pictures = <Uint8List>[];
  for (var i = 1; i <= 4; i++) {
    final data = await rootBundle
        .load('assets/report_scenes/scene-${i.toString().padLeft(2, '0')}.jpg');
    pictures.add(data.buffer.asUint8List());
  }
  Api.I.configure('http://story-preview.invalid', 'preview-only');
  Api.I.dio.httpClientAdapter = _PreviewAdapter(pictures);
  runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (_, child) => Banner(
          message: '演示数据', location: BannerLocation.topEnd, child: child!),
      home: const ReportListPage()));
}

class _PreviewAdapter implements HttpClientAdapter {
  _PreviewAdapter(this.pictures);
  final List<Uint8List> pictures;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final match = RegExp(r'/api/asset/(\d+)/').firstMatch(options.path);
    if (match != null) {
      return ResponseBody.fromBytes(
          pictures[(int.parse(match[1]!) - 1) % pictures.length], 200,
          headers: {
            Headers.contentTypeHeader: ['image/jpeg']
          });
    }
    final day = options.queryParameters['day'] ?? '2026-09-20';
    final sample = storySample()..['day'] = day;
    sample['pool'] = [
      for (var id = 1; id <= 4; id++)
        {
          'id': id,
          'kind': 'image',
          'persons': [1, 2],
          'uploader_id': 12,
          'likes': id,
          'comments': 0,
          'taken_w': id * 1000,
        }
    ];
    return ResponseBody.fromString(
        jsonEncode(options.path.endsWith('/story')
            ? sample
            : {
                'identity': {'person_id': 1, 'name': '小雨'},
                'next': null,
                'days': [
                  for (var i = 20; i >= 16; i--)
                    {
                      'day': '2026-09-$i',
                      'photos': 18,
                      'videos': 2,
                      'mine': 7,
                      'cover_id': 21 - i
                    }
                ],
              }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}
