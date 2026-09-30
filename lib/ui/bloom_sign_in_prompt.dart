import 'package:flutter/material.dart';

import 'bloom_glass_home.dart';

/// 各页未登录时共用的「去登录」提示。
///
/// 为什么是一个共用组件而不是每页各写一份：四个页面（首页/照片/设备/我的）
/// 都要在未登录时挡一下，如果各写一份，很快就会出现四处措辞、间距、按钮宽度
/// 各不相同的情况 —— 而这类"没功能只有提示"的界面最容易被复制粘贴后改歪。
///
/// 它刻意**不自带页面骨架**（标题栏、SafeArea 由各页自己给）：每个页面的
/// 标题和留白规则不同，把骨架也塞进来反而要加一堆开关参数。
class BloomSignInPrompt extends StatelessWidget {
  const BloomSignInPrompt({
    super.key,
    required this.title,
    required this.message,
    required this.onSignIn,
    this.icon = Icons.lock_outline_rounded,
    this.illustration,
    this.buttonLabel = '登录',
    this.busy = false,
  });

  final String title;
  final String message;

  /// 点「登录」要做什么。为 null 时按钮禁用（例如正在处理上一次点击）。
  final VoidCallback? onSignIn;

  /// 无自定义插画时显示的图标。
  final IconData icon;

  /// 页面自己的插画。给了它就忽略 [icon] —— 照片页那张「空相框」是既有设计，
  /// 不该为了统一而被一个通用图标替换掉。
  final Widget? illustration;

  final String buttonLabel;

  /// 登录相关操作进行中，期间禁用按钮避免重复触发。
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      // 左右留白比页面 inset 更大：这组内容整体居中，贴边会显得局促。
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          illustration ??
              Icon(icon, size: 34, color: BloomInk.textFaint),
          const SizedBox(height: 22),
          Text(title, textAlign: TextAlign.center, style: BloomType.rowTitle),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: BloomType.body,
          ),
          const SizedBox(height: 26),
          // 固定宽度而不是撑满：撑满的按钮在四个页面上宽度各不相同，
          // 看起来像四套不同的设计。
          SizedBox(
            width: 168,
            child: BloomPrimaryButton(
              label: buttonLabel,
              loading: busy,
              onPressed: busy ? null : onSignIn,
            ),
          ),
        ],
      ),
    ),
  );
}
