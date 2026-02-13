import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart' as ckjar;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/main.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/network/request.dart';
import 'package:hikari_novel_flutter/service/local_storage_service.dart';

/// 內嵌式 Cloudflare 挑戰解決 Widget
/// 預設使用隱藏 WebView 自動解決，必要時可切到手動互動模式。
class CloudflareResolverWidget extends StatefulWidget {
  /// 挑戰解決成功後的回調
  final VoidCallback? onResolved;

  /// 超時秒數（預設 60 秒）
  final int timeoutSeconds;

  /// 目標 URL（觸發 challenge 的 URL），如果為 null 則使用預設首頁
  final String? targetUrl;

  /// 是否啟用可互動的手動驗證模式
  final bool enableManualPass;

  const CloudflareResolverWidget({
    super.key,
    this.onResolved,
    this.timeoutSeconds = 60,
    this.targetUrl,
    this.enableManualPass = false,
  });

  @override
  State<CloudflareResolverWidget> createState() => _CloudflareResolverWidgetState();
}

class _CloudflareResolverWidgetState extends State<CloudflareResolverWidget> {
  InAppWebViewController? _webViewController;
  final CookieManager _cookieManager = CookieManager.instance(webViewEnvironment: webViewEnvironment);
  String _status = 'initializing';
  bool _resolved = false;
  bool _timedOut = false;
  bool _handoffInProgress = false;
  bool _likelyEnvironmentBlocked = false;
  int? _mainFrameStatusCode;
  Timer? _pollTimer;
  DateTime? _interactiveSince;
  late String _currentUrl;

  final InAppWebViewSettings _settings = InAppWebViewSettings(
    isInspectable: kDebugMode,
    applicationNameForUserAgent: 'HikariNovel',
    javaScriptEnabled: true,
    domStorageEnabled: true,
    databaseEnabled: true,
    useShouldOverrideUrlLoading: true,
    useOnLoadResource: true,
    javaScriptCanOpenWindowsAutomatically: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    safeBrowsingEnabled: false,
    thirdPartyCookiesEnabled: true,
    allowFileAccessFromFileURLs: true,
    allowUniversalAccessFromFileURLs: true,
    cacheEnabled: true,
    mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
  );

  String get _targetUrl => widget.targetUrl ?? Wenku8Node.wwwWenku8Net.node;

  @override
  void initState() {
    super.initState();
    _currentUrl = _targetUrl;
    if (kDebugMode) {
      print('CloudflareResolver: Initializing with targetUrl=$_targetUrl');
    }
    // 啟動超時計時器
    Future.delayed(Duration(seconds: widget.timeoutSeconds), () {
      if (mounted && !_resolved) {
        setState(() {
          _timedOut = true;
          _status = 'timeout';
        });
        if (kDebugMode) {
          print('CloudflareResolver: ⏱️ TIMEOUT after ${widget.timeoutSeconds}s');
        }
      }
    });
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _resolved || _handoffInProgress) return;
      final uri = await _webViewController?.getUrl();
      if (uri != null) {
        await _syncCookies(uri);
      }
    });
  }

  void _handleConsoleHint(String msg) {
    final lower = msg.toLowerCase();
    if (lower.contains('private access token') || lower.contains('failed to create webgpu context provider')) {
      if (!_likelyEnvironmentBlocked && mounted) {
        setState(() => _likelyEnvironmentBlocked = true);
      } else {
        _likelyEnvironmentBlocked = true;
      }
    }
  }

  Future<_PageSignals> _detectPageSignals() async {
    if (_webViewController == null) return const _PageSignals(status: 'unknown');

    final result = await _webViewController!.evaluateJavascript(source: """
      (function() {
        const title = document.title || "";
        const lowerTitle = title.toLowerCase();
        const body = document.body ? document.body.innerHTML : "";
        const lowerBody = body.toLowerCase();
        const href = location.href || "";
        
        function tryAutoClick() {
          const checkbox = document.querySelector('input[type="checkbox"]');
          if (checkbox) { checkbox.click(); return true; }
          return false;
        }

        const hasTurnstile = lowerBody.includes('cf-turnstile') ||
          !!document.querySelector('.cf-turnstile') ||
          href.includes('__cf_chl_rt_tk=');
        const hasChallengeScript = lowerBody.includes('cdn-cgi/challenge-platform') ||
          lowerBody.includes('cf-browser-verification') ||
          lowerBody.includes('cf-chl');
        const hasCloudflareTitle = lowerTitle.includes('just a moment') ||
          lowerTitle.includes('attention required') ||
          lowerTitle.includes('access denied') ||
          lowerTitle.includes('sorry, you have been blocked');
        const hasErrorDetails = !!document.querySelector('#cf-error-details');
        const hasContent = !!document.getElementById('content');
        const hasCenters = !!document.getElementById('centers');
        const blockedText = lowerTitle.includes('sorry, you have been blocked') ||
          lowerBody.includes('you have been blocked') ||
          lowerBody.includes('error code 1020') ||
          lowerBody.includes('access denied');

        if (hasTurnstile || document.querySelector('#challenge-stage')) {
          tryAutoClick();
        }

        let status = 'passed';
        if (hasErrorDetails || blockedText) {
          status = 'blocked';
        } else if (document.getElementById('cf-please-wait') || hasCloudflareTitle || hasTurnstile || hasChallengeScript) {
          status = hasTurnstile ? 'interactive' : 'waiting';
        }

        return JSON.stringify({
          status,
          title,
          href,
          hasContent,
          hasCenters,
          hasTurnstile,
          hasChallengeScript,
          hasCloudflareTitle,
        });
      })();
    """);

    try {
      Map<String, dynamic> map;
      if (result is Map) {
        map = Map<String, dynamic>.from(result as Map);
      } else {
        final raw = result?.toString();
        if (raw == null || raw.isEmpty) {
          return const _PageSignals(status: 'unknown');
        }
        final unescaped = raw.replaceAll(RegExp(r'^"|"$'), '').replaceAll(r'\"', '"');
        final decoded = jsonDecode(unescaped);
        if (decoded is! Map) return const _PageSignals(status: 'unknown');
        map = decoded.cast<String, dynamic>();
      }
      return _PageSignals(
        status: (map['status']?.toString() ?? 'unknown').toLowerCase(),
        title: map['title']?.toString() ?? '',
        href: map['href']?.toString() ?? '',
        hasContent: map['hasContent'] == true,
        hasCenters: map['hasCenters'] == true,
        hasTurnstile: map['hasTurnstile'] == true,
        hasChallengeScript: map['hasChallengeScript'] == true,
        hasCloudflareTitle: map['hasCloudflareTitle'] == true,
      );
    } catch (_) {
      return const _PageSignals(status: 'unknown');
    }
  }

  Future<void> _syncCookies(WebUri uri, {bool manualTrigger = false}) async {
    if (_resolved || _handoffInProgress) return;

    final signals = await _detectPageSignals();
    var status = signals.status;

    // If WebView main-frame returns 403 and it's clearly Cloudflare, treat as blocked.
    if (_mainFrameStatusCode == 403 && (signals.hasCloudflareTitle || signals.hasChallengeScript || signals.hasTurnstile)) {
      status = 'blocked';
    }

    if (status == 'interactive') {
      _interactiveSince ??= DateTime.now();
    } else {
      _interactiveSince = null;
    }
    if (!_likelyEnvironmentBlocked && _interactiveSince != null) {
      final waited = DateTime.now().difference(_interactiveSince!);
      if (waited.inSeconds >= 25) {
        // If Turnstile stays interactive too long, it is very likely blocked by environment (emulator/IP).
        _likelyEnvironmentBlocked = true;
      }
    }

    if (mounted) {
      setState(() => _status = status);
      if (kDebugMode) {
        print('CloudflareResolver: status=$status, resolved=$_resolved');
      }
    }

    final cookies = await _cookieManager.getCookies(url: uri);
    if (cookies.isEmpty && kDebugMode) {
      print('CloudflareResolver: No cookies found');
    }

    bool hasClearance = false;
    final hasCloudflareCookie = cookies.any((c) => c.name == 'cf_clearance' || c.name.startsWith('__cf') || c.name.startsWith('cf_'));

    final jarCookies = cookies.map((c) {
      if (c.name == 'cf_clearance') hasClearance = true;

      try {
        final rawDomain = (c.domain?.toString() ?? '').trim();
        final normalizedDomain = rawDomain.replaceFirst(RegExp(r'^\\.'), '');
        final rawPath = (c.path?.toString() ?? '').trim();

        final cookie = ckjar.Cookie(c.name, c.value.toString())
          ..domain = normalizedDomain.isEmpty ? null : normalizedDomain
          ..path = rawPath.isEmpty ? "/" : rawPath
          ..httpOnly = c.isHttpOnly ?? false
          ..secure = c.isSecure ?? false;

        if (c.expiresDate != null) {
          cookie.expires = _normalizeCookieExpiry(c.expiresDate!);
        }

        return cookie;
      } catch (_) {
        // Skip cookies with invalid values (e.g., containing commas)
        if (kDebugMode) {
          print('Skipping invalid cookie ${c.name}: unsupported value format');
        }
        return null;
      }
    }).where((c) => c != null).cast<ckjar.Cookie>().toList();

    if (jarCookies.isNotEmpty) {
      Request.saveWenku8Cookies(jarCookies);
    }

    if (kDebugMode) {
      print('CloudflareResolver: Synced ${jarCookies.length} cookies, hasClearance=$hasClearance, status=$status');
      final names = jarCookies.map((c) => c.name).join(', ');
      print('CloudflareResolver: cookie names => $names');
    }

    final reachedTargetPath = _isSamePathAsTarget(uri);
    final expectedDomReady = _hasExpectedDomForTarget(uri, signals);
    final mainFrameOk = _mainFrameStatusCode == null || (_mainFrameStatusCode! >= 200 && _mainFrameStatusCode! < 400);

    // Some Cloudflare modes don't expose cf_clearance to app-side cookie APIs.
    // If the WebView is already at the target path and no longer looks like a Cloudflare interstitial,
    // allow handoff even if DOM heuristics are imperfect.
    final canResolve =
        (hasClearance && status == 'passed') ||
        (reachedTargetPath && status == 'passed' && mainFrameOk && !signals.hasChallenge) ||
        // Keep the old "expected DOM" shortcut as an extra safety net.
        (reachedTargetPath && expectedDomReady && mainFrameOk && !signals.hasChallenge) ||
        // Manual "continue" should be able to hand off even if cookie APIs are empty on some devices.
        (manualTrigger && reachedTargetPath && status == 'passed' && mainFrameOk && !signals.hasChallenge);

    if (kDebugMode) {
      print(
        'CloudflareResolver: canResolve=$canResolve, reachedTargetPath=$reachedTargetPath, '
        'expectedDomReady=$expectedDomReady, hasCloudflareCookie=$hasCloudflareCookie',
      );
    }

    if (canResolve) {
      _resolved = true;
      _handoffInProgress = true;
      if (mounted) {
        setState(() => _status = 'resolved');
      }

      // Snapshot solved page HTML for login fallback path.
      try {
        final rawHtml = await _webViewController?.evaluateJavascript(
          source: 'document.documentElement.outerHTML',
        );
        if (rawHtml != null) {
          // iOS/WKWebView often returns a JSON-escaped string. Normalize it before caching.
          final normalized = _normalizeHtmlFromJsResult(rawHtml.toString());
          Request.setLastResolvedHtmlSnapshotForUrl(_currentUrl, normalized);
        }
      } catch (_) {}

      // Sync WebView UA to Dio so Cloudflare accepts the cookies
      try {
        final webViewUA = await _webViewController?.evaluateJavascript(
          source: 'navigator.userAgent',
        );
        if (webViewUA != null && webViewUA.toString().isNotEmpty) {
          Request.updateUserAgent(webViewUA.toString());
        }
      } catch (_) {}

      if (kDebugMode) {
        print('CloudflareResolver: ✅ Challenge RESOLVED! Calling onResolved()');
      }
      // 短暫延遲確保 cookie 生效
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        widget.onResolved?.call();
      } finally {
        _handoffInProgress = false;
      }
      return;
    }

    if (manualTrigger && mounted) {
      if (cookies.isEmpty) {
        Get.snackbar(
          "Cloudflare",
          "目前仍無法取得 Cookie（可能尚未真正通過或 WebView Cookie API 受限），請稍後再按一次或改用其他網路/節點。",
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3),
        );
        return;
      }
      if (status == 'blocked') {
        Get.snackbar(
          "Cloudflare",
          "目前節點疑似被封鎖（403），無法在 App 內自動通關。請切換節點或更換網路後重試。",
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3),
        );
        return;
      }
      Get.snackbar(
        "Cloudflare",
        "請先在下方完成 Turnstile 驗證，再按一次繼續",
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final webViewHeight = (MediaQuery.of(context).size.height * 0.42).clamp(240.0, 420.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 狀態指示器
        if ((_status == 'initializing' || _status == 'loading') && !_timedOut && !_resolved) ...[
          const SizedBox(height: 16),
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 12),
          Text(
            _getStatusText(),
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],

        if (_status == 'interactive' && !_resolved) ...[
          const SizedBox(height: 12),
          const Icon(Icons.touch_app, size: 28),
          const SizedBox(height: 6),
          Text(
            "請先在下方完成 Turnstile 驗證，再按「我已完成驗證，繼續」",
            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],

        if (_status == 'waiting' && !_resolved) ...[
          const SizedBox(height: 12),
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(height: 6),
          Text(
            "cloudflare_challenge_processing".tr,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],

        if (_resolved) ...[
          const SizedBox(height: 16),
          Icon(Icons.check_circle, color: Colors.green, size: 32),
          const SizedBox(height: 8),
          Text(
            "cloudflare_resolved".tr,
            style: TextStyle(color: Colors.green, fontSize: 13),
          ),
        ],

        if (_timedOut) ...[
          const SizedBox(height: 16),
          Icon(Icons.warning_amber, color: Colors.orange, size: 32),
          const SizedBox(height: 8),
          Text(
            "cloudflare_timeout".tr,
            style: TextStyle(color: Colors.orange, fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh),
            label: Text("retry".tr),
          ),
        ],

        if (_likelyEnvironmentBlocked) ...[
          const SizedBox(height: 8),
          Text(
            "目前環境可能被 Cloudflare 風險判定，建議改用真機與行動網路",
            style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],

        if (_status == 'blocked' || _status == 'interactive' || _status == 'waiting') ...[
          const SizedBox(height: 8),
          Text(
            _status == 'blocked' ? "目前節點已被封鎖，可切換站點重試" : "若長時間無法通過，可嘗試切換站點",
            style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _switchNodeAndRetry,
            icon: const Icon(Icons.swap_horiz),
            label: const Text("切換節點並重試"),
          ),
        ],

        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: _copyDiagnostics,
          icon: const Icon(Icons.copy, size: 18),
          label: const Text("複製診斷資訊"),
        ),

        if (widget.enableManualPass) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: webViewHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: InAppWebView(
                key: ValueKey(_currentUrl),
                initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
                initialSettings: _settings,
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
                onLoadStop: (controller, uri) {
                  if (uri != null) _syncCookies(uri);
                },
                onUpdateVisitedHistory: (controller, uri, isReload) {
                  if (uri != null) _syncCookies(uri);
                },
                onTitleChanged: (controller, title) async {
                  final uri = await controller.getUrl();
                  if (uri != null) _syncCookies(uri);
                },
                onReceivedHttpError: (controller, request, response) {
                  if (request.isForMainFrame == true) {
                    _mainFrameStatusCode = response.statusCode;
                  }
                },
                onConsoleMessage: (controller, consoleMessage) {
                  _handleConsoleHint(consoleMessage.message);
                  _detectPageSignals().then((signals) {
                    if (mounted) setState(() => _status = signals.status);
                  });
                },
                onProgressChanged: (controller, progress) {
                  if (mounted && _status == 'initializing' && progress > 10) {
                    setState(() => _status = 'loading');
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _onManualContinuePressed,
            icon: const Icon(Icons.check),
            label: const Text("我已完成驗證，繼續"),
          ),
        ] else
          SizedBox(
            width: 1,
            height: 1,
            child: Opacity(
              opacity: 0,
              child: InAppWebView(
                key: ValueKey(_currentUrl),
                initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
                initialSettings: _settings,
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
                onLoadStop: (controller, uri) {
                  if (uri != null) _syncCookies(uri);
                },
                onUpdateVisitedHistory: (controller, uri, isReload) {
                  if (uri != null) _syncCookies(uri);
                },
                onTitleChanged: (controller, title) async {
                  final uri = await controller.getUrl();
                  if (uri != null) _syncCookies(uri);
                },
                onReceivedHttpError: (controller, request, response) {
                  if (request.isForMainFrame == true) {
                    _mainFrameStatusCode = response.statusCode;
                  }
                },
                onConsoleMessage: (controller, consoleMessage) {
                  _handleConsoleHint(consoleMessage.message);
                  _detectPageSignals().then((signals) {
                    if (mounted) setState(() => _status = signals.status);
                  });
                },
                onProgressChanged: (controller, progress) {
                  if (mounted && _status == 'initializing' && progress > 10) {
                    setState(() => _status = 'loading');
                  }
                },
              ),
            ),
          ),
      ],
    );
  }

  String _getStatusText() {
    switch (_status) {
      case 'initializing':
      case 'loading':
        return "cloudflare_resolving".tr;
      case 'interactive':
        return "請在下方完成 Turnstile 驗證";
      case 'waiting':
        return "cloudflare_challenge_processing".tr;
      case 'blocked':
        return "cloudflare_blocked".tr;
      case 'resolved':
        return "cloudflare_resolved".tr;
      default:
        return "cloudflare_resolving".tr;
    }
  }

  void _retry() {
    setState(() {
      _timedOut = false;
      _resolved = false;
      _status = 'initializing';
      _handoffInProgress = false;
    });
    _webViewController?.reload();
    // 重新啟動超時計時器
    Future.delayed(Duration(seconds: widget.timeoutSeconds), () {
      if (mounted && !_resolved) {
        setState(() {
          _timedOut = true;
          _status = 'timeout';
        });
      }
    });
  }

  Future<void> _onManualContinuePressed() async {
    final uri = await _webViewController?.getUrl();
    if (uri == null) return;
    if (kDebugMode) {
      print('CloudflareResolver: Manual continue pressed, url=$uri');
    }
    await _syncCookies(uri, manualTrigger: true);
  }

  Future<void> _switchNodeAndRetry() async {
    final current = LocalStorageService.instance.getWenku8Node();
    final next = current == Wenku8Node.wwwWenku8Net ? Wenku8Node.wwwWenku8Cc : Wenku8Node.wwwWenku8Net;
    LocalStorageService.instance.setWenku8Node(next);
    Request.deleteCookie();
    await _cookieManager.deleteAllCookies();

    final switchedUrl = _replaceHostWithNode(_currentUrl, next);
    setState(() {
      _timedOut = false;
      _resolved = false;
      _status = 'initializing';
      _handoffInProgress = false;
      _likelyEnvironmentBlocked = false;
      _interactiveSince = null;
      _currentUrl = switchedUrl;
    });

    // Also trigger retry of the original request using the new node.
    // This covers cases where the new node doesn't require solving Turnstile.
    widget.onResolved?.call();

    if (mounted) {
      Get.snackbar(
        "Cloudflare",
        "已切換到 ${next.node}，請重新完成驗證",
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    }
  }

  DateTime _normalizeCookieExpiry(int rawExpires) {
    // Some WebView platforms return seconds while others return milliseconds.
    final normalizedMs = rawExpires < 1000000000000 ? rawExpires * 1000 : rawExpires;
    return DateTime.fromMillisecondsSinceEpoch(normalizedMs);
  }

  String _normalizeHtmlFromJsResult(String raw) {
    // Try JSON decode first: some platforms return a quoted/escaped JSON string.
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
    } catch (_) {}

    // Fallback: remove wrapping quotes and unescape common sequences.
    final s = raw.toString();
    final unwrapped = s.replaceAll(RegExp(r'^"|"$'), '');
    return unwrapped.replaceAll(r'\"', '"').replaceAll(r'\\n', '\n').replaceAll(r'\\t', '\t');
  }

  bool _isSamePathAsTarget(WebUri currentUri) {
    final targetUri = Uri.tryParse(_currentUrl);
    if (targetUri == null) return false;
    return currentUri.host == targetUri.host && currentUri.path == targetUri.path;
  }

  bool _hasExpectedDomForTarget(WebUri currentUri, _PageSignals signals) {
    final path = currentUri.path.toLowerCase();
    if (path.contains('/index.php')) return signals.hasCenters || signals.hasContent;
    return signals.hasContent || signals.hasCenters;
  }

  String _replaceHostWithNode(String url, Wenku8Node node) {
    final src = Uri.tryParse(url);
    final dst = Uri.parse(node.node);
    if (src == null) return node.node;
    return src.replace(scheme: dst.scheme, host: dst.host, port: dst.hasPort ? dst.port : null).toString();
  }

  Future<void> _copyDiagnostics() async {
    final uri = await _webViewController?.getUrl();
    final effectiveUri = uri ?? WebUri(_currentUrl);
    final signals = await _detectPageSignals();
    final cookies = await _cookieManager.getCookies(url: effectiveUri);
    final cookieNames = cookies.map((c) => c.name).toList()..sort();
    final cookieDetails = cookies
        .map(
          (c) => <String, Object?>{
            'name': c.name,
            'domain': c.domain,
            'path': c.path,
            'expiresDate': c.expiresDate,
            'isHttpOnly': c.isHttpOnly,
            'isSecure': c.isSecure,
            'isSessionOnly': c.isSessionOnly,
            'sameSite': c.sameSite,
          },
        )
        .toList();

    String? webViewUA;
    try {
      final ua = await _webViewController?.evaluateJavascript(source: 'navigator.userAgent');
      if (ua != null) webViewUA = ua.toString();
    } catch (_) {}

    List<String> dioCookieJarNames = <String>[];
    try {
      final jarCookies = await Request.cookieJar.loadForRequest(Uri.parse(effectiveUri.toString()));
      dioCookieJarNames = jarCookies.map((c) => c.name).toSet().toList()..sort();
    } catch (_) {}

    final payload = <String, Object?>{
      'targetUrl': _currentUrl,
      'effectiveUrl': effectiveUri.toString(),
      'title': signals.title,
      'status': signals.status,
      'mainFrameStatusCode': _mainFrameStatusCode,
      'reachedTargetPath': _isSamePathAsTarget(effectiveUri),
      'hasChallenge': signals.hasChallenge,
      'hasTurnstile': signals.hasTurnstile,
      'hasChallengeScript': signals.hasChallengeScript,
      'hasCloudflareTitle': signals.hasCloudflareTitle,
      'cookieCount': cookies.length,
      'cookieNames': cookieNames,
      'cookieDetails': cookieDetails,
      'dioCookieJarCookieNamesForEffectiveUrl': dioCookieJarNames,
      'webViewUA': webViewUA,
      'dioUA': Request.dio.options.headers['user-agent']?.toString(),
      'savedUA': LocalStorageService.instance.getWebViewUA(),
      'node': LocalStorageService.instance.getWenku8Node().node,
    };

    final text = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      Get.snackbar(
        "Cloudflare",
        "已複製診斷資訊到剪貼簿",
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    }
  }
}

class _PageSignals {
  final String status;
  final String title;
  final String href;
  final bool hasContent;
  final bool hasCenters;
  final bool hasTurnstile;
  final bool hasChallengeScript;
  final bool hasCloudflareTitle;

  const _PageSignals({
    required this.status,
    this.title = '',
    this.href = '',
    this.hasContent = false,
    this.hasCenters = false,
    this.hasTurnstile = false,
    this.hasChallengeScript = false,
    this.hasCloudflareTitle = false,
  });

  bool get hasChallenge => hasTurnstile || hasChallengeScript || hasCloudflareTitle;
}
