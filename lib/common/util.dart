import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/models/resource.dart';
import 'package:hikari_novel_flutter/service/local_storage_service.dart';
import 'package:jiffy/jiffy.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/common/language.dart';
import '../network/api.dart';

class Util {
  static String getDateTime(String dateStr) {
    if (!LocalStorageService.instance.getIsRelativeTime()) {
      return dateStr;
    }
    final DateTime inputDate = DateTime.parse(dateStr);
    return Jiffy.parse(inputDate.toString()).fromNow();
  }

  static Locale getCurrentLocale() {
    final language = LocalStorageService.instance.getLanguage();
    if (language == Language.followSystem) {
      if (Get.deviceLocale == Locale("zh", "CN")) {
        return Locale("zh", "CN");
      } else if (Get.deviceLocale == Locale("zh", "TW")) {
        return Locale("zh", "TW");
      } else {
        return Locale("zh", "CN");
      }
    }
    return switch (language) {
      Language.simplifiedChinese => Locale("zh", "CN"),
      Language.traditionalChinese => Locale("zh", "TW"),
      _ => Locale("zh", "CN"),
    };
  }

  static Future<dynamic> _isLatestVersionAvail() async {
    final response = await Api.fetchLatestRelease();
    if (response is Success) {
      final data = response.data;
      final remoteVer = data['tag_name']; // e.g. "1.2.3-beta.2+2"

      final info = await PackageInfo.fromPlatform();
      final localVer = info.version; // e.g. "1.2.0-beta.2"

      late Version currRemoteVer;

      try {
        currRemoteVer = Version.parse(remoteVer.toString().substring(0, remoteVer.toString().indexOf("+")));
      } catch (_) {
        currRemoteVer = Version.parse(remoteVer.toString());
      }

      final currLocalVer = Version.parse(localVer.toString());

      return currRemoteVer > currLocalVer;
    } else {
      return response.error.toString();
    }
  }

  static Future<void> checkUpdate(bool mustNotification) async {
    final result = await _isLatestVersionAvail();

    if (result is bool) {
      final bool hasNewVersion = result;

      //不需要通知且没有新版本，直接返回
      if (!mustNotification && !hasNewVersion) return;

      final List<Widget> actions = [
        if (hasNewVersion) TextButton(onPressed: () => launchUrl(Uri.parse("https://github.com/15dd/hikari_novel_flutter/releases")), child: Text("go_to_update".tr)),
        TextButton(onPressed: Get.back, child: Text("confirm".tr)),
      ];

      Get.dialog(
        AlertDialog(
          title: Text("check_update".tr),
          content: Text(hasNewVersion ? "new_version_available".tr : "no_new_version_available".tr),
          actions: actions,
        ),
      );

      return;
    }

    if (result is String && mustNotification) {
      Get.dialog(
        AlertDialog(
          title: Text("check_update".tr),
          content: Text(result),
          actions: [TextButton(onPressed: Get.back, child: Text("confirm".tr))],
        ),
      );
    }
  }
}
