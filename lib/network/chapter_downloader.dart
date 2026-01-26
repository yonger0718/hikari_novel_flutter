import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class ChapterDownloader {
  final Map<String, CancelToken> _cancelTokens = {}; // taskId -> CancelToken

  void cancel(String taskId) {
    final token = _cancelTokens[taskId];
    if (token != null && !token.isCancelled) token.cancel('canceled');
    _cancelTokens.remove(taskId);
  }

  void clearCancel(String taskId) {
    _cancelTokens.remove(taskId);
  }

  // bool _isCanceled(String taskId) => _cancelTokens[taskId]?.isCancelled ?? false;

  /// 使用 POST 获取流并保存到 app documents 目录，返回本地路径
  Future<String> download(String taskId, String aid, String cid) async {
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory("${dir.path}/cached_chapter");
    if (!(await cacheDir.exists())) {
      await cacheDir.create(recursive: true);
    }

    final savePath = "${cacheDir.path}/${aid}_$cid.txt";
    final cancelToken = CancelToken();
    _cancelTokens[taskId] = cancelToken;

    //FIXME 重写缓存
    try {
      // 网络请求
      Response response = await Dio().get("");
      try {
        // response = await Api.getNovelContent(aid: aid, cid: cid);
      } on DioException catch (e) {
        _cancelTokens.remove(taskId);
        if (e.type == DioExceptionType.cancel) {
          throw Exception('canceled');
        }
        rethrow; // 直接抛出网络异常
      }

      if (cancelToken.isCancelled) throw Exception("canceled");

      final content = response.data?.toString() ?? "";

      // 写文件
      try {
        final file = File(savePath);
        await file.writeAsString(content);
      } catch (ioe) {
        // 文件写入失败
        final file = File(savePath);
        if (await file.exists()) await file.delete();
        rethrow;
      }

      _cancelTokens.remove(taskId);
      return savePath;
    } finally {
      _cancelTokens.remove(taskId);
    }
  }
}
