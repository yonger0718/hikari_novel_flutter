import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:cookie_jar/cookie_jar.dart' as ckjar;
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart' as dio_cm;
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iwbv;
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/models/custom_exception.dart';
import 'package:hikari_novel_flutter/models/resource.dart';

import '../common/log.dart';
import '../models/common/charsets_type.dart';
import '../service/local_storage_service.dart';
import 'api.dart';

/// 网络请求
class Request {
  /// 獲取當前使用的 UserAgent Map (相容舊代碼)
  static Map<String, String> get userAgent => {
    io.HttpHeaders.userAgentHeader: dio.options.headers[io.HttpHeaders.userAgentHeader] ??
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  };

  static final _dioCookieJar = ckjar.CookieJar();
  static ckjar.CookieJar get cookieJar => _dioCookieJar;
  static String? _lastResolvedHtmlSnapshot;
  static Future<void> _webViewQueue = Future.value();

  static void setLastResolvedHtmlSnapshot(String html) {
    _lastResolvedHtmlSnapshot = html;
  }

  static String? consumeLastResolvedHtmlSnapshot() {
    final value = _lastResolvedHtmlSnapshot;
    _lastResolvedHtmlSnapshot = null;
    return value;
  }
  static final Dio dio = Dio(
    BaseOptions(
      // 初始 UA，稍後會被 WebView 覆蓋
      headers: {
        io.HttpHeaders.userAgentHeader:
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      },
      responseType: ResponseType.bytes, //使用bytes获取原始数据，方便解码
      followRedirects: true, // 允許重定向
      validateStatus: (status) => status != null, //只要不是 null，就交给拦截器处理,
    ),
  )
    ..interceptors.add(CloudflareInterceptor(cookieJar: _dioCookieJar))
    ..interceptors.add(dio_cm.CookieManager(_dioCookieJar));

  static Map<String, String> _browserLikeHeaders({String? referer, bool includeOrigin = false}) {
    final base = "${Api.wenku8Node.node}/";
    final headers = <String, String>{
      io.HttpHeaders.acceptHeader: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      io.HttpHeaders.acceptLanguageHeader: "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7",
      io.HttpHeaders.cacheControlHeader: "no-cache",
      io.HttpHeaders.pragmaHeader: "no-cache",
      "Upgrade-Insecure-Requests": "1",
      io.HttpHeaders.refererHeader: referer ?? base,
    };
    if (includeOrigin) {
      headers['Origin'] = Api.wenku8Node.node;
    }
    return headers;
  }

  /// 更新 Dio 的 UserAgent 以匹配 WebView，並持久化
  static void updateUserAgent(String ua) {
    final normalizedUA = ua.trim().replaceAll(RegExp(r'^"|"$'), '');
    dio.options.headers[io.HttpHeaders.userAgentHeader] = normalizedUA;
    LocalStorageService.instance.setWebViewUA(normalizedUA);
    Log.d("UserAgent updated: $normalizedUA");
  }

  static void initCookie() {
    final localCookie = LocalStorageService.instance.getCookie();

    // Restore persisted WebView UA
    final savedUA = LocalStorageService.instance.getWebViewUA();
    if (savedUA != null && savedUA.isNotEmpty) {
      dio.options.headers[io.HttpHeaders.userAgentHeader] = savedUA;
    }

    if (localCookie == null) return;

    final cookies = localCookie.split(';').map((e) => e.trim()).where((e) => e.contains('=')).map((e) {
      final kv = e.split('=');
      return ckjar.Cookie(kv[0], kv.sublist(1).join('='));
    }).toList();

    saveWenku8Cookies(cookies);
  }

  static void deleteCookie() => _dioCookieJar.deleteAll();

  static void saveWenku8Cookies(List<ckjar.Cookie> cookies) {
    final netCookies = <ckjar.Cookie>[];
    final ccCookies = <ckjar.Cookie>[];

    for (final cookie in cookies) {
      final domain = (cookie.domain ?? '').toLowerCase();
      if (domain.contains('wenku8.net')) {
        netCookies.add(cookie);
        continue;
      }
      if (domain.contains('wenku8.cc')) {
        ccCookies.add(cookie);
        continue;
      }

      // Domain-less or unknown-domain cookies are copied to both nodes.
      netCookies.add(cookie);
      ccCookies.add(cookie);
    }

    if (netCookies.isNotEmpty) {
      _dioCookieJar.saveFromResponse(Uri.parse(Wenku8Node.wwwWenku8Net.node), netCookies);
    }
    if (ccCookies.isNotEmpty) {
      _dioCookieJar.saveFromResponse(Uri.parse(Wenku8Node.wwwWenku8Cc.node), ccCookies);
    }
  }

  static Future<T> _runInWebViewQueue<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _webViewQueue = _webViewQueue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static DateTime _normalizeCookieExpiry(int rawExpires) {
    final normalizedMs = rawExpires < 1000000000000 ? rawExpires * 1000 : rawExpires;
    return DateTime.fromMillisecondsSinceEpoch(normalizedMs);
  }

  static String _normalizeHtmlFromJsResult(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
    } catch (_) {}
    return raw;
  }

  static bool _looksLikeCloudflareHtml(String html) {
    final lower = html.toLowerCase();
    return lower.contains('attention required! | cloudflare') ||
        lower.contains('cdn-cgi/challenge-platform') ||
        lower.contains('cf-browser-verification') ||
        lower.contains('cf-chl') ||
        lower.contains('cf-error-details') ||
        lower.contains('just a moment') && lower.contains('cloudflare');
  }

  static bool _looksLikeCloudflareTitle(String? title) {
    if (title == null || title.isEmpty) return false;
    final lower = title.toLowerCase();
    return lower.contains('attention required! | cloudflare') ||
        lower.contains('just a moment') ||
        lower.contains('access denied') ||
        lower.contains('sorry, you have been blocked');
  }

  static bool _looksLikeExpectedHtml(String url, String html) {
    final lower = html.toLowerCase();
    if (_looksLikeCloudflareHtml(html)) return false;

    if (url.contains('/userdetail.php')) {
      return lower.contains('id="content"') || lower.contains("id='content'");
    }
    if (url.contains('/modules/article/bookcase.php')) {
      final hasContent = lower.contains('id="content"') || lower.contains("id='content'");
      final hasBookshelfControls = lower.contains('name="checkall"') ||
          lower.contains("name='checkall'") ||
          lower.contains('newclassid');
      return hasContent && hasBookshelfControls;
    }
    if (url.contains('/index.php')) {
      final hasCenters = lower.contains('id="centers"') || lower.contains("id='centers'");
      final hasRecommendBlock = lower.contains('class="blocktitle"') || lower.contains("class='blocktitle'");
      return hasCenters && hasRecommendBlock;
    }
    return true;
  }

  // Headless WebView fallback is only useful for a few flows.
  // For most pages (e.g. detail/tags) Turnstile requires visible user interaction.
  static bool _shouldUseHeadlessFallback(String url) {
    return url.contains('/userdetail.php') || url.contains('/modules/article/bookcase.php') || url.contains('/index.php');
  }

  static List<ckjar.Cookie> _webViewCookiesToJar(List<dynamic> cookies) {
    return cookies.map((c) {
      try {
        final cookie = ckjar.Cookie(c.name, c.value.toString())
          ..domain = c.domain
          ..path = c.path
          ..httpOnly = c.isHttpOnly ?? false
          ..secure = c.isSecure ?? false;
        if (c.expiresDate != null) {
          cookie.expires = _normalizeCookieExpiry(c.expiresDate!);
        }
        return cookie;
      } catch (_) {
        return null;
      }
    }).where((c) => c != null).cast<ckjar.Cookie>().toList();
  }

  static Future<String?> _getByWebView(String url) {
    if (kIsWeb) return Future.value(null);
    return _runInWebViewQueue(() async {
      final cookieManager = iwbv.CookieManager.instance();
      final completer = Completer<String?>();
      var finished = false;
      var hasMainFrameHttpError = false;
      var hasCloudflareTitle = false;
      int? mainFrameStatusCode;
      late final iwbv.HeadlessInAppWebView headless;

      Future<void> done(String? html) async {
        if (finished) return;
        finished = true;
        if (!completer.isCompleted) {
          completer.complete(html);
        }
        try {
          await headless.dispose();
        } catch (_) {}
      }

      headless = iwbv.HeadlessInAppWebView(
        initialUrlRequest: iwbv.URLRequest(url: iwbv.WebUri(url)),
        initialSettings: iwbv.InAppWebViewSettings(
          isInspectable: kDebugMode,
          applicationNameForUserAgent: 'HikariNovel',
          javaScriptEnabled: true,
          mixedContentMode: iwbv.MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          thirdPartyCookiesEnabled: true,
          cacheEnabled: true,
        ),
        onLoadStop: (controller, uri) async {
          try {
            if (uri != null) {
              final webViewCookies = await cookieManager.getCookies(url: uri);
              final jarCookies = _webViewCookiesToJar(webViewCookies);
              if (jarCookies.isNotEmpty) {
                saveWenku8Cookies(jarCookies);
              }
            }
            final webViewUA = await controller.evaluateJavascript(source: 'navigator.userAgent');
            if (webViewUA != null && webViewUA.toString().isNotEmpty) {
              updateUserAgent(webViewUA.toString());
            }

            final rawHtml = await controller.evaluateJavascript(source: 'document.documentElement.outerHTML');
            if (rawHtml == null) {
              await done(null);
              return;
            }
            final normalizedHtml = _normalizeHtmlFromJsResult(rawHtml.toString());
            if (hasMainFrameHttpError || hasCloudflareTitle || !_looksLikeExpectedHtml(url, normalizedHtml)) {
              if (kDebugMode) {
                Log.e(
                  "WebView fallback rejected -> status=${mainFrameStatusCode ?? 'none'}, "
                  "cloudflareTitle=$hasCloudflareTitle, url=$url",
                );
              }
              await done(null);
              return;
            }
            await done(normalizedHtml);
          } catch (_) {
            await done(null);
          }
        },
        onTitleChanged: (_, title) {
          if (_looksLikeCloudflareTitle(title)) {
            hasCloudflareTitle = true;
          }
        },
        onReceivedHttpError: (_, request, response) {
          if (request.isForMainFrame == true && (response.statusCode ?? 0) >= 400) {
            hasMainFrameHttpError = true;
            mainFrameStatusCode = response.statusCode;
          }
        },
        onReceivedError: (_, request, _) async {
          if (request.isForMainFrame == true) {
            hasMainFrameHttpError = true;
          }
          await done(null);
        },
      );

      await headless.run();
      return completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () async {
          await done(null);
          return null;
        },
      );
    });
  }

  ///获取通用数据（如其他网站的数据，即不用wenku8的cookie）
  /// - [url] 对应网站的url
  static Future<Resource> getCommonData(String url) async {
    try {
      final dio = Dio(BaseOptions(headers: Request.dio.options.headers));
      final response = await dio.get(url);
      return Success(response.data);
    } catch (e) {
      return Error(e.toString());
    }
  }

  ///获取wenku8数据
  /// - [url] 对应的url
  /// - [charsetsType] response解码的方式
  static Future<Resource> get(String url, {required CharsetsType charsetsType}) async {
    try {
      if (!url.contains("?")) url += "?";
      switch (charsetsType) {
        case CharsetsType.gbk:
          url += "&charset=gbk";
        case CharsetsType.big5Hkscs:
          url += "&charset=big5";
      }

      Log.d("$url ${charsetsType.name}");

      final response = await dio.get(
        url,
        options: Options(
          headers: _browserLikeHeaders(),
        ),
      );

      //检查是否有重定向
      final result = await _checkRedirects(response);

      final raw = result as Uint8List;
      late String decodedHtml;
      switch (charsetsType) {
        case CharsetsType.gbk:
          decodedHtml = GbkDecoder().convert(raw);
        case CharsetsType.big5Hkscs:
          decodedHtml = Big5Decoder().convert(raw);
      }

      if (!_looksLikeExpectedHtml(url, decodedHtml)) {
        return Error("Cloudflare Challenge Detected (Unexpected HTML Content) [URL: $url]");
      }

      return Success(decodedHtml);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains("Cloudflare Challenge Detected")) {
        if (!_shouldUseHeadlessFallback(url)) {
          Log.d("Skip headless Cloudflare fallback for interactive page: $url");
          Log.e(e.toString());
          return Error(e.toString());
        }

        Log.d("Cloudflare fallback via WebView start: $url");
        final fallbackHtml = await _getByWebView(url);
        if (fallbackHtml != null && fallbackHtml.isNotEmpty && _looksLikeExpectedHtml(url, fallbackHtml)) {
          Log.d("Cloudflare fallback via WebView succeeded: $url");
          return Success(fallbackHtml);
        }
        Log.e("Cloudflare fallback via WebView failed: $url");
      }
      Log.e(e.toString());
      return Error(e.toString());
    }
  }

  /// 检查Response包中是否要求重定向
  /// - [response] 要检查的Response包
  static Future<dynamic> _checkRedirects(Response response) async {
    if (response.statusCode != null && response.statusCode! >= 300 && response.statusCode! < 400) {
      final location = response.headers.value('location');
      if (location != null) {
        final redirectedResponse = await dio.get(
          "${Api.wenku8Node.node}/$location",
          options: Options(
            headers: _browserLikeHeaders(referer: response.requestOptions.uri.toString()),
          ),
        );
        return redirectedResponse.data;
      }
    }
    return response.data;
  }

  /// 以post方法进行http请求
  /// body以Content-Type: application/x-www-form-urlencoded的形式进行发送
  /// - [url] 要请求的url
  /// - [data] 此post请求的body，当body中含有url编码的内容时，需要使用String类型而非Map类型！目前不知道是什么原因，可能是因为dio的二次编码？
  /// - [charsetsType] response解码的方式
  static Future<Resource> postForm(String url, {required Object? data, required CharsetsType charsetsType}) async {
    try {
      final response = await dio.post(
        url,
        data: data,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: _browserLikeHeaders(referer: url, includeOrigin: true),
        ), //设置为application/x-www-form-urlencoded
      );
      String decodedHtml;
      switch (charsetsType) {
        case CharsetsType.gbk:
          {
            decodedHtml = GbkCodec().decode(response.data as Uint8List);
          }
        case CharsetsType.big5Hkscs:
          {
            decodedHtml = Big5Codec().decode(response.data as Uint8List);
          }
      }
      return Success(decodedHtml);
    } catch (e) {
      Log.e(e.toString());
      return Error(e.toString());
    }
  }
}

class CloudflareInterceptor extends Interceptor {

  final ckjar.CookieJar cookieJar;



  CloudflareInterceptor({required this.cookieJar});



  @override

  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) async {

    final server = response.headers.value('server');

    final isCloudflare = server?.toLowerCase().contains('cloudflare') ?? false;

    final statusCode = response.statusCode;



    // NOTE: cf-mitigated header is UNRELIABLE and causes false positives.
    // Pages can load successfully despite having this header.
    // Removed this check to avoid unnecessary challenge triggers.
    //
    // final cfMitigated = response.headers.value('cf-mitigated');
    // if (cfMitigated != null && cfMitigated.contains('challenge')) {
    //   handler.reject(CloudflareChallengeException(...));
    //   return;
    // }



    // Only check for actual blocking status codes (403/503)

    if (isCloudflare && (statusCode == 403 || statusCode == 503)) {

      String type = "Unknown";

      if (statusCode == 403) type = "403 Forbidden / Possible Blocked";

      if (statusCode == 503) type = "503 Service Unavailable / JS Challenge";



      if (kDebugMode) {
        final cookieHeader = response.requestOptions.headers[io.HttpHeaders.cookieHeader]?.toString() ?? "";
        final cookieNames = cookieHeader
            .split(';')
            .map((e) => e.trim())
            .where((e) => e.contains('='))
            .map((e) => e.split('=').first)
            .join(', ');
        final ua = response.requestOptions.headers[io.HttpHeaders.userAgentHeader]?.toString() ?? "";
        Log.e("Cloudflare debug -> status=$statusCode, cookies=[${cookieNames.isEmpty ? 'none' : cookieNames}], ua=${ua.isEmpty ? 'none' : ua}");
      }

      handler.reject(CloudflareChallengeException(

        requestOptions: response.requestOptions,

        message: "Cloudflare Challenge Detected ($type) [URL: ${response.requestOptions.uri}]",

      ));

      return;

    }



    handler.next(response);

  }

}
