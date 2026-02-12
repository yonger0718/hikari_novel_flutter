import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/main.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/models/page_state.dart';
import 'package:hikari_novel_flutter/network/request.dart';
import 'package:hikari_novel_flutter/router/route_path.dart';
import 'package:cookie_jar/cookie_jar.dart' as ckjar;

import '../../common/database/database.dart';
import '../../models/resource.dart';
import '../../network/api.dart';
import '../../network/parser.dart';
import '../../service/db_service.dart';
import '../../service/local_storage_service.dart';

class LoginController extends GetxController {
  RxBool showLoading = true.obs;
  RxInt loadingProgress = 0.obs;
  final CookieManager cookieManager = CookieManager.instance(webViewEnvironment: webViewEnvironment);
  InAppWebViewController? inAppWebViewController;
  final GlobalKey webViewKey = GlobalKey();
  final InAppWebViewSettings settings = InAppWebViewSettings(
    isInspectable: kDebugMode,
    applicationNameForUserAgent: 'HikariNovel',
    javaScriptEnabled: true,
    mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
  );
  RxString currentUrl = "".obs;

  Rx<PageState> pageState = PageState.success.obs;
  String errorMsg = "";
  bool _isFinishingLogin = false;
  bool _waitingCloudflareResolve = false;

  String get url => "${Api.wenku8Node.node}/login.php";

  @override
  void onInit() {
    super.onInit();
    cookieManager.deleteAllCookies();
  }

  Future<void> saveCookie(WebUri uri) async {
    if (_waitingCloudflareResolve) return;
    if (_isFinishingLogin) return;
    showLoading.value = false;

    //存储cookie
    if (uri.toString().contains("wenku8") == true) {
      final getCookie = await cookieManager.getCookies(url: uri);

      bool hasCookie = ["jieqiUserInfo", "jieqiVisitInfo"].every(
        (keyword) => getCookie.any((cookieItem) => cookieItem.name.contains(keyword)),
      ); //getCookie.any((cookieItem) => cookieItem.name == "jieqiUserInfo");
      if (hasCookie) {
        _isFinishingLogin = true;
        String cookie = "jieqiUserInfo=${getCookie.firstWhere((cookieItem) => cookieItem.name == "jieqiUserInfo").value};";
        cookie += "jieqiVisitInfo=${getCookie.firstWhere((cookieItem) => cookieItem.name == "jieqiVisitInfo").value}";
        LocalStorageService.instance.setCookie(cookie);
        // Avoid duplicate cookie entries (local persisted + webview sync).
        Request.deleteCookie();

        // CRITICAL: Sync ALL WebView cookies to Dio (not just the 2 saved ones)
        // This includes session cookies, Cloudflare cookies, etc.
        final allCookies = getCookie.map((c) {
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
            if (kDebugMode) {
              print('Skipping invalid cookie ${c.name}: unsupported value format');
            }
            return null;
          }
        }).where((c) => c != null).cast<ckjar.Cookie>().toList();

        Request.saveWenku8Cookies(allCookies);

        // CRITICAL: Sync WebView UA to Dio
        // Cloudflare binds cf_clearance cookie to User-Agent.
        // If Dio sends a different UA, the cookie won't work → 403.
        try {
          final webViewUA = await inAppWebViewController?.evaluateJavascript(
            source: 'navigator.userAgent',
          );
          if (webViewUA != null && webViewUA.toString().isNotEmpty) {
            Request.updateUserAgent(webViewUA.toString());
          }
        } catch (e) {
          if (kDebugMode) {
            print('Failed to get WebView UA: $e');
          }
        }

        if (kDebugMode) {
          print('Synced ${allCookies.length} cookies from WebView to Dio');
          final cookieNames = allCookies.map((c) => c.name).join(', ');
          print('Synced cookie names: $cookieNames');
        }

        try {
          await _getUserInfo();
        } catch (e) {
          errorMsg = e.toString();
          pageState.value = PageState.error;

          // Cloudflare 挑戰允許透過 resolver 手動完成後重試，不要提前清空狀態
          if (!_isCloudflareChallengeError(e)) {
            _clearLoginState();
          } else {
            _waitingCloudflareResolve = true;
          }

          _isFinishingLogin = false;
          return;
        }

        // 書架預載失敗不應阻斷登入
        try {
          await _refreshBookshelf();
        } catch (_) {}

        _isFinishingLogin = false;
        Get.offAllNamed(RoutePath.main);
      }
    }
  }

  void handleErrorAction() {
    if (errorMsg.contains("Cloudflare Challenge Detected")) {
      retryAfterCloudflare();
      return;
    }
    pageState.value = PageState.success;
  }

  Future<void> retryAfterCloudflare() async {
    if (_isFinishingLogin) return;
    _waitingCloudflareResolve = false;
    _isFinishingLogin = true;
    pageState.value = PageState.success;

    try {
      try {
        await _getUserInfo();
      } catch (e) {
        if (_isCloudflareChallengeError(e)) {
          final recovered = await _recoverUserInfoFromCurrentWebView();
          if (!recovered) {
            // 最後保底：已有登入 cookie 就先放行進主頁，避免卡在 challenge 畫面
            if ((LocalStorageService.instance.getCookie() ?? '').isNotEmpty) {
              if (kDebugMode) {
                print('Cloudflare fallback: proceed to main with persisted login cookie');
              }
              Get.offAllNamed(RoutePath.main);
              return;
            }

            errorMsg = e.toString();
            pageState.value = PageState.error;
            _waitingCloudflareResolve = true;
            return;
          }
        } else {
          errorMsg = e.toString();
          pageState.value = PageState.error;
          _clearLoginState();
          return;
        }
      }

      // 書架刷新不是登入必要條件，避免再次被 Cloudflare 卡住流程
      try {
        await _refreshBookshelf();
      } catch (_) {}
      Get.offAllNamed(RoutePath.main);
    } finally {
      _isFinishingLogin = false;
    }
  }

  bool _isCloudflareChallengeError(Object e) => e.toString().contains("Cloudflare Challenge Detected");

  Future<bool> _recoverUserInfoFromCurrentWebView() async {
    final htmlCandidates = <String>[];

    try {
      final rawHtml = await inAppWebViewController?.evaluateJavascript(
        source: 'document.documentElement.outerHTML',
      );
      if (rawHtml != null) {
        htmlCandidates.add(rawHtml.toString());
      }
    } catch (_) {}

    final resolvedSnapshot = Request.consumeLastResolvedHtmlSnapshot();
    if (resolvedSnapshot != null && resolvedSnapshot.isNotEmpty) {
      htmlCandidates.add(resolvedSnapshot);
    }

    for (final raw in htmlCandidates) {
      final html = _normalizeHtmlFromJsResult(raw);
      if (html.isEmpty) continue;

      try {
        final userInfo = Parser.getUserInfo(html);
        LocalStorageService.instance.setUserInfo(userInfo);
        if (kDebugMode) {
          print('Recovered user info from WebView HTML fallback');
        }
        return true;
      } catch (_) {
        continue;
      }
    }

    return false;
  }

  String _normalizeHtmlFromJsResult(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
    } catch (_) {}
    return raw;
  }

  DateTime _normalizeCookieExpiry(int rawExpires) {
    // Some WebView platforms return seconds while others return milliseconds.
    final normalizedMs = rawExpires < 1000000000000 ? rawExpires * 1000 : rawExpires;
    return DateTime.fromMillisecondsSinceEpoch(normalizedMs);
  }

  void _clearLoginState() {
    LocalStorageService.instance.setCookie(null);
    LocalStorageService.instance.setWebViewUA(null);
    Request.deleteCookie();
    inAppWebViewController?.dispose();
  }

  Future<void> _getUserInfo() async {
    final data = await Api.getUserInfo();
    switch (data) {
      case Success():
        {
          try {
            LocalStorageService.instance.setUserInfo(Parser.getUserInfo(data.data));
          } catch (_) {
            throw "Cloudflare Challenge Detected (UserInfo Parse Failed)";
          }
        }
      case Error():
        {
          throw data.error;
        }
    }
  }

  Future<void> _refreshBookshelf() async {
    await DBService.instance.deleteAllBookshelf();

    for (int index = 0; index < 6; index++) {
      try {
        await _insertAll(index);
      } catch (_) {}
      // Avoid burst traffic that may trigger Cloudflare risk controls.
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _insertAll(int index) async {
    final result = await Api.getBookshelf(classId: index);
    switch (result) {
      case Success():
        {
          final bookshelf = Parser.getBookshelf(result.data, index);
          if (bookshelf.list.isNotEmpty) {
            final insertData = bookshelf.list.map((e) {
              return BookshelfEntityData(aid: e.aid, bid: e.bid, url: e.url, title: e.title, img: e.img, classId: bookshelf.classId.toString());
            });
            await DBService.instance.insertAllBookshelf(insertData);
          }
        }
      case Error():
        {
          throw result.error;
        }
    }
  }
}
