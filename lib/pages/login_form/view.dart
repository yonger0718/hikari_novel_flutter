import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../router/route_path.dart';
import 'controller.dart';

class LoginFormPage extends StatefulWidget {
  const LoginFormPage({super.key});

  @override
  State<LoginFormPage> createState() => _LoginFormPageState();
}

class _LoginFormPageState extends State<LoginFormPage> {
  final controller = Get.put(LoginFormController());
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  /// Login cookie validity (seconds) that Wenku8 expects via `usecookie`.
  ///
  /// Matches the original Android app mapping:
  /// - Only once: 0
  /// - 1 day: 86400
  /// - 1 month: 2592000
  /// - 1 year: 315360000 (kept as-is for compatibility with the original app)
  String _usecookieSeconds = "86400";

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keep the bottom-left "go to web" entry pinned when the keyboard shows.
    // We will handle keyboard overlap by adding viewInsets.bottom to the
    // scrollable content padding instead of letting Scaffold resize the body.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                // Keep extra bottom space so the fixed "go to web" button never covers
                // the login CTA (prevents mis-taps).
                padding: EdgeInsets.fromLTRB(24, 16, 24, 96 + bottomInset),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Top logo (horizontally centered)
                      Center(
                        child: Image.asset(
                          'assets/images/logo_transparent.png',
                          width: 140,
                          height: 140,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'HiKari Novel',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _usernameCtrl,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        decoration: InputDecoration(
                          labelText: 'username'.tr,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passwordCtrl,
                        obscureText: true,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'password'.tr,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _onLogin(),
                      ),
                      const SizedBox(height: 12),

                      // Validity selector (bottom sheet)
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: _showValiditySheet,
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'login_validity'.tr,
                            border: const OutlineInputBorder(),
                            isDense: true,
                            suffixIcon: const Icon(Icons.arrow_drop_down),
                          ),
                          child: Text(_validityLabel(_usecookieSeconds)),
                        ),
                      ),

                      const SizedBox(height: 16),
                      Obx(
                            () => FilledButton.icon(
                          onPressed:
                          controller.isSubmitting.value ? null : _onLogin,
                          icon: controller.isSubmitting.value
                              ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                              : const Icon(Icons.login),
                          label: Text(
                            controller.isSubmitting.value
                                ? 'logging_in'.tr
                                : 'login'.tr,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'login_form_tip'.tr,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),

            // Fixed bottom-left entry, matching the original layout.
            Positioned(
              left: 12,
              bottom: 8,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                ),
                onPressed: () => Get.toNamed(RoutePath.webLogin),
                icon: const Icon(Icons.public),
                label: Text('go_to_web_login'.tr),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _validityLabel(String seconds) {
    switch (seconds) {
      case "0":
        return 'only_once'.tr;
      case "86400":
        return 'one_day'.tr;
      case "2592000":
        return 'one_month'.tr;
      case "315360000":
        return 'one_year'.tr;
      default:
        return seconds;
    }
  }

  void _showValiditySheet() {
    FocusScope.of(context).unfocus();

    final items = <MapEntry<String, String>>[
      const MapEntry("0", "only_once"),
      const MapEntry("86400", "one_day"),
      const MapEntry("2592000", "one_month"),
      const MapEntry("315360000", "one_year"),
    ];

    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          shrinkWrap: true,
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final value = items[index].key;
            final labelKey = items[index].value;
            final selected = value == _usecookieSeconds;
            return ListTile(
              title: Text(labelKey.tr),
              trailing: selected ? const Icon(Icons.check) : null,
              onTap: () {
                setState(() => _usecookieSeconds = value);
                Navigator.of(context).pop();
              },
            );
          },
        );
      },
    );
  }

  void _onLogin() {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      Get.dialog(
        AlertDialog(
          title: Text('error'.tr),
          content: Text('login_input_required'.tr),
          actions: [
            TextButton(
              onPressed: () => Get.back(),
              child: Text('confirm'.tr),
            ),
          ],
        ),
      );
      return;
    }

    controller.login(
      username: username,
      password: password,
      usecookieSeconds: _usecookieSeconds,
    );
  }
}