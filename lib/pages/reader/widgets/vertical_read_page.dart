import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:get/get.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../router/route_path.dart';
import '../../../network/request.dart';

class VerticalReadPage extends StatefulWidget {
  final String text;
  final List<String> images;
  final int initPosition;
  final EdgeInsets padding;
  final TextStyle style;
  final ScrollController controller;
  final Function(double position, double max) onScroll;

  const VerticalReadPage(
    this.text,
    this.images, {
    required this.initPosition,
    required this.padding,
    required this.style,
    required this.controller,
    required this.onScroll,
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _VerticalReadPageState();
}

class _VerticalReadPageState extends State<VerticalReadPage> with WidgetsBindingObserver {
  String text = "";
  List<String> images = [];

  TextStyle textStyle = TextStyle();
  EdgeInsets padding = EdgeInsets.zero;

  late String _lastLayoutSig;

  @override
  void initState() {
    super.initState();
    _lastLayoutSig = _layoutSignature();
    WidgetsBinding.instance.addObserver(this);
    resetPage();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.jumpTo(widget.initPosition.toDouble());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void resetPage() {
    text = widget.text;
    textStyle = widget.style;
    images = List<String>.from(widget.images); //转换为纯净的List<String>
    padding = widget.padding;
    if (text.isEmpty && images.isEmpty) {
      setState(() {});
      return;
    }
  }

  @override
  void didUpdateWidget(covariant VerticalReadPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    //这里比较排版几何参数（fontSize, textStyle）是否有变化
    //这里不能使用"widget.xxx != oldWidget.xxx"，这是在比较对象，而不是比较其中的参数。比如深浅模式切换导致页面重建，会重建TextStyle对象实例，最终误判
    final newSig = _layoutSignature();
    if (newSig != _lastLayoutSig) {
      _lastLayoutSig = newSig;
      if (widget.text != oldWidget.text && listEquals(widget.images, oldWidget.images)) {
        //判断章节是否切换
        setState(() {});
      }
      resetPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        widget.onScroll(notification.metrics.pixels, notification.metrics.maxScrollExtent);
        return true;
      },
      child: SingleChildScrollView(
        controller: widget.controller,
        child: Padding(
          padding: padding,
          child: Column(
            children: [
              HtmlWidget('<div style="text-align: justify;">${text.replaceAll('\n', '<br>')}</div>', textStyle: textStyle, enableCaching: true),
              ...images.asMap().entries.map(
                (entry) => GestureDetector(
                  onDoubleTap: () => Get.toNamed(RoutePath.photo, arguments: {"gallery_mode": true, "list": images, "index": entry.key}),
                  onLongPress: () => Get.toNamed(RoutePath.photo, arguments: {"gallery_mode": true, "list": images, "index": entry.key}),
                  child: CachedNetworkImage(
                    width: double.infinity,
                    imageUrl: images[entry.key],
                    httpHeaders: Request.userAgent,
                    fit: BoxFit.fitWidth,
                    progressIndicatorBuilder: (context, url, downloadProgress) => Center(child: CircularProgressIndicator(value: downloadProgress.progress)),
                    errorWidget: (context, url, error) => Column(children: [Icon(Icons.error_outline), Text(error.toString())]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  //排版几何参数的签名
  String _layoutSignature() {
    final s = widget.style;
    final p = widget.padding;

    return [
      widget.text.length,
      widget.images.length,
      s.fontSize,
      s.height,
      s.letterSpacing,
      s.wordSpacing,
      s.color?.toARGB32(),
      p.left,
      p.right,
      p.top,
      p.bottom,
    ].join("|");
  }
}
