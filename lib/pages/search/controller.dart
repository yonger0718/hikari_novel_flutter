import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/models/novel_cover.dart';
import 'package:hikari_novel_flutter/models/page_state.dart';
import 'package:hikari_novel_flutter/models/resource.dart';
import 'package:hikari_novel_flutter/network/parser.dart';

import '../../common/database/database.dart';
import '../../network/api.dart';
import '../../service/db_service.dart';

class SearchController extends GetxController {
  SearchController({required this.author});

  final String? author;

  final keywordController = TextEditingController();

  RxInt searchMode = 0.obs;
  RxList<String> searchHistory = RxList();

  Rx<PageState> pageState = Rx(PageState.pleaseSelect);

  /// 站点会在短时间内频繁搜索时返回“出现错误！”页面。
  /// 这里做一个简单的冷却，避免用户连续点搜索历史导致看起来“没反应”。
  RxInt cooldownSeconds = 0.obs;
  Timer? _cooldownTimer;

  /// 冷却期间用户最后一次点的关键词（用于自动排队搜索）
  RxString pendingKeyword = ''.obs;
  int? _pendingSearchMode;

  String errorMsg = "";

  int _maxNum = 1;
  int _index = 0;
  final RxList<NovelCover> data = RxList();

  @override
  void onReady() {
    super.onReady();

    DBService.instance.getAllSearchHistory().listen((sh) {
      searchHistory.assignAll(sh.reversed.map((e) => e.keyword));
    });

    checkIsAuthorSearch(author);
  }

  void checkIsAuthorSearch(String? author) {
    if (author != null) {
      keywordController.text = author;
      searchMode.value = 1;
      getPage(false);
    }
  }

  /// 点击“搜索历史”后直接触发搜索
  void searchFromHistory(String keyword) {
    keywordController.text = keyword;
    keywordController.selection = TextSelection.fromPosition(
      TextPosition(offset: keywordController.text.length),
    );
    // 直接执行搜索
    getPage(false);
    // 顺便收起键盘
    Get.focusScope?.unfocus();
  }

  void _showCooldownTip() {
    // 复用「保存图片成功/失败」同款提示风格：浮动 Snackbar + 图标 + 两行文字
    final theme = Get.theme;
    final cs = theme.colorScheme;
    final isDark = Get.isDarkMode ||
        theme.brightness == Brightness.dark ||
        cs.brightness == Brightness.dark;

    // 亮色：白底黑字；暗色：深色底白字
    final bgColor = isDark
        ? const Color(0xFF1F1F1F).withOpacity(0.95)
        : Colors.white.withOpacity(0.95);
    final textColor = isDark ? Colors.white : Colors.black87;
    final shadowColor =
        isDark ? Colors.black.withOpacity(0.45) : Colors.black.withOpacity(0.15);

    // 防止连点时堆叠很多提示
    Get.closeAllSnackbars();

    Get.snackbar(
      '雑魚雑魚❤️点那么是准备快爬虫嘛',
      // 用短句 + 自动换行；如果未来文案变长，也会在空格/标点处自然断行
      '等5秒会自动搜索这不是Bug',
      snackPosition: SnackPosition.BOTTOM,
      snackStyle: SnackStyle.FLOATING,

      // 两侧留白更大 => 视觉更“窄”，更协调
      margin: const EdgeInsets.symmetric(horizontal: 36, vertical: 12),

      // 圆角稍小一点
      borderRadius: 12,

      backgroundColor: bgColor,
      colorText: textColor,

      // 图标从「✔」改为「×」
      icon: Icon(
        Icons.cancel_rounded,
        color: cs.primary,
      ),

      // 让高度接近原来的 2 倍：增加上下 padding
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),

      duration: const Duration(seconds: 2),
      isDismissible: true,
      shouldIconPulse: false,
      boxShadows: [
        BoxShadow(
          color: shadowColor,
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ],

      // 文字居中（与「保存图片」一致风格）
      titleText: Text(
        '雑魚雑魚❤️点那么是准备快爬虫嘛',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      messageText: Text(
        '等5秒会自动搜索这不是Bug',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: textColor,
          fontSize: 13,
          height: 1.35,
        ),
      ),
    );
  }


  void _startCooldown() {
  // 站点提示：两次搜索间隔不得少于 5 秒
  _cooldownTimer?.cancel();
  cooldownSeconds.value = 5;
  _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
    if (cooldownSeconds.value <= 1) {
      timer.cancel();
      cooldownSeconds.value = 0;

      // 冷却结束：恢复显示状态
      if (pageState.value == PageState.inFiveSecond) {
        pageState.value = data.isNotEmpty ? PageState.success : PageState.pleaseSelect;
      }

      // 冷却结束后：如果用户在冷却期点了新的搜索历史，自动执行“最后一次”
      final kw = pendingKeyword.value;
      final mode = _pendingSearchMode;
      if (kw.isNotEmpty) {
        pendingKeyword.value = '';
        _pendingSearchMode = null;

        // 恢复当时的模式（标题/作者）
        if (mode != null) searchMode.value = mode;
        keywordController.text = kw;
        keywordController.selection = TextSelection.fromPosition(
          TextPosition(offset: keywordController.text.length),
        );

        // 自动搜索最后一次点击的关键词
        getPage(false);
      }
    } else {
      cooldownSeconds.value -= 1;
    }
  });
  }


  Future<IndicatorResult> getPage(bool loadMore) async {
    // 冷却中：不再重复发请求；把“最后一次点击的关键词”排队，冷却结束后自动搜索
    if (!loadMore && cooldownSeconds.value > 0) {
      pendingKeyword.value = keywordController.text;
      _pendingSearchMode = searchMode.value;

      _showCooldownTip();
      return IndicatorResult.fail;
    }
    if (!loadMore) pageState.value = PageState.loading;

    if (!loadMore) {
      // 新的搜索开始，清空排队提示
      pendingKeyword.value = '';
      _pendingSearchMode = null;

      DBService.instance.upsertSearchHistory(SearchHistoryEntityData(keyword: keywordController.text));

      data.clear();
      _index = 0;
    }
    if (_index >= _maxNum) {
      return IndicatorResult.noMore;
    }
    _index += 1;

    Resource result;
    if (searchMode.value == 0) {
      result = await Api.searchNovelByTitle(title: keywordController.text, index: _index);
    } else {
      result = await Api.searchNovelByAuthor(author: keywordController.text, index: _index);
    }

    switch (result) {
      case Success():
        {
          final html = result.data;
          if (Parser.isError(html)) {
            if (!loadMore) {
              // 搜索过快：进入冷却，但不显示遮罩层、不切换页面状态（保持可操作）
              // 排队一次“最后的关键词”，冷却结束后自动重试
              pendingKeyword.value = keywordController.text;
              _pendingSearchMode = searchMode.value;

              pageState.value = data.isNotEmpty ? PageState.success : PageState.pleaseSelect;
              _startCooldown();

              _showCooldownTip();
            } else {
              Get.dialog(
                AlertDialog(
                  title: Text("warning".tr),
                  content: Text("search_too_quickly_tip".tr),
                  actions: [TextButton(onPressed: Get.back, child: Text("confirm".tr))],
                ),
              );
            }

            return IndicatorResult.fail;
          }

          // 站点在“只有 1 条搜索结果”时会返回一个特殊页面。
          // 以前这里会自动跳转到详情页，但体验上会让用户
          // （尤其是从“搜索历史”点进来时）无法先看到结果列表。
          // 现在统一改为：即使只有 1 本，也先展示搜索结果列表，
          // 让用户自己点一下再进入详情。
          var tempResult = Parser.isSearchResultOnlyOne(html);
          if (tempResult != null) {
            data.add(tempResult);
            _maxNum = 1;
            if (!loadMore) pageState.value = PageState.success;
            return IndicatorResult.noMore;
          }
          if (!loadMore) _maxNum = Parser.getMaxNum(html);

          final parsedHtml = Parser.parseToList(html);

          if (parsedHtml.isEmpty) {
            pageState.value = PageState.empty;
            return IndicatorResult.noMore;
          }

          data.addAll(parsedHtml);
          if (!loadMore) pageState.value = PageState.success;
          return IndicatorResult.success;
        }
      case Error():
        {
          if (!loadMore) {
            errorMsg = result.error;
            pageState.value = PageState.error;
          } else {
            Get.dialog(
              AlertDialog(
                title: Text("error".tr),
                content: Text(result.error.toString()),
                actions: [TextButton(onPressed: () => Get.back(), child: Text("confirm".tr))],
              ),
            );
          }
          if (_index > 0) {
            _index -= 1;
          }
          return IndicatorResult.fail;
        }
    }
  }
@override
void onClose() {
  _cooldownTimer?.cancel();
  keywordController.dispose();
  super.onClose();
}
}