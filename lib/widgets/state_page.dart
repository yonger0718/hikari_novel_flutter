import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/widgets/cloudflare_resolver_widget.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

class ErrorMessage extends StatelessWidget {
  const ErrorMessage({super.key, required this.msg, required this.action, this.buttonText = "retry", this.iconData = Icons.refresh});

  final String msg;
  final Function()? action;
  final String buttonText;
  final IconData iconData;

  @override
  Widget build(BuildContext context) {
    if (msg.contains("Cloudflare Challenge Detected")) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: _CloudflareAutoResolver(action: action, errorMsg: msg),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            "error".tr,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
          ),
          Padding(padding: EdgeInsets.symmetric(vertical: 10, horizontal: 20), child: _buildErrorInfo()),
          action == null ? Container() : FilledButton.icon(onPressed: action, icon: Icon(iconData), label: Text(buttonText.tr)),
        ],
      ),
    );
  }

  Widget _buildErrorInfo() {
    return SingleChildScrollView(child: Text(msg));
  }
}

/// 偵測到 Cloudflare 挑戰時，嵌入 WebView 協助通關（可手動互動）
class _CloudflareAutoResolver extends StatelessWidget {
  final Function()? action;
  final String errorMsg;

  const _CloudflareAutoResolver({required this.action, required this.errorMsg});

  @override
  Widget build(BuildContext context) {
    // Extract URL from error message like "... [URL: https://...]"
    String? challengeUrl;
    final urlMatch = RegExp(r'\[URL: ([^\]]+)\]').firstMatch(errorMsg);
    if (urlMatch != null) {
      challengeUrl = urlMatch.group(1);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "cloudflare_challenge_exception_tip".tr,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        // 內嵌式自動解決 widget
        CloudflareResolverWidget(
          targetUrl: challengeUrl,
          enableManualPass: true,
          onResolved: () {
            if (action != null) action!();
          },
        ),
      ],
    );
  }
}

class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class LogoPage extends StatelessWidget {
  const LogoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(child: Image.asset("assets/images/logo_transparent.png", width: 150, height: 150));
  }
}

class PleaseSelectPage extends StatelessWidget {
  const PleaseSelectPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Symbols.web_traffic, size: 48),
          const SizedBox(height: 16),
          Text("please_select_type".tr, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class EmptyPage extends StatelessWidget {
  final Function()? onRefresh;

  const EmptyPage({super.key, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox, size: 48),
          const SizedBox(height: 16),
          Text("empty_content".tr, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          onRefresh != null ? TextButton.icon(onPressed: onRefresh, icon: Icon(Icons.refresh), label: Text("refresh".tr)) : const SizedBox(),
        ],
      ),
    );
  }
}

Future showErrorDialog(String msg, List<Widget> actions, {Function()? action}) {
  late Widget content;

  if (msg.contains("Cloudflare Challenge Detected")) {
    content = _CloudflareAutoResolver(action: action, errorMsg: msg);
  } else {
    content = SingleChildScrollView(child: Text(msg));
  }

  return Get.dialog(AlertDialog(title: Text("error".tr), content: content, actions: actions));
}

//参考https://pub.dev/packages/floating_snackbar
void showSnackBar({
  required String message, // The message to display in the SnackBar
  required BuildContext context, // The BuildContext to show the SnackBar within
  Duration? duration, // Optional: Duration for which the SnackBar is displayed
  TextStyle? textStyle, // Optional: Text style for the message text
}) {
  // Create a SnackBar widget with specified properties
  var snack = SnackBar(
    margin: const EdgeInsets.symmetric(vertical: 20, horizontal: 10), // Set margin around the SnackBar
    duration: duration ?? const Duration(milliseconds: 4000), // Default duration if not provided
    content: Text(
      message, // Display the provided message text
      style: textStyle ?? TextStyle(), // Apply provided or default text style
    ),
  );

  // Hide any currently displayed SnackBar
  ScaffoldMessenger.of(context).hideCurrentSnackBar();

  // Show the created SnackBar
  ScaffoldMessenger.of(context).showSnackBar(snack);
}
