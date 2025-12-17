import 'package:dio/dio.dart';

import '../download_library.dart';

class SourceDetector{
  final Dio dio;
  SourceDetector(this.dio);

  Future<SourceKind> detect(String url)async{
    final lower = url.toLowerCase();
    if(lower.endsWith('.m3u8')) return SourceKind.hls;
    if(lower.endsWith('.mp4')) return SourceKind.mp4;
    try{
      final resp = await dio.head(url, options: Options(followRedirects: true));
      final ct = (resp.headers.value('content-type')??'').toLowerCase();
      if (ct.contains('application/vnd.apple.mpegurl') || ct.contains('application/x-mpegurl')) {
        return SourceKind.hls;
      }
      if (ct.contains('video/mp4')) return SourceKind.mp4;
    }catch(_){}
    //兜底
    return SourceKind.hls;
  }
}
