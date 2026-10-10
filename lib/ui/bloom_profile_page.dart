import 'package:flutter/material.dart';

import '../core/models/auth_models.dart';
import 'bloom_glass_home.dart';
import 'bloom_sign_in_prompt.dart';

/// 「我的」页（底部导航第 4 个 tab）。
///
/// 存在的理由：登录态之前是挂在「设备」页底部的一个小角落里的 —— 那是个
/// 临时位置。账号属于"这个人"，不属于"设备"，所以它需要自己的一页。
///
/// 未登录时这一页只做一件事：把人送到登录页。这一页**没有**"部分可见"的
/// 状态 —— 没有账号就没有"我的"可言。
class BloomProfilePage extends StatelessWidget {
  const BloomProfilePage({
    super.key,
    required this.account,
    required this.onSignIn,
    this.onSignOut,
    this.busy = false,
  });

  final AccountInfo? account;
  final VoidCallback? onSignIn;
  final VoidCallback? onSignOut;

  /// 登录/登出进行中，期间禁用操作。
  final bool busy;

  @override
  Widget build(BuildContext context) => SafeArea(
    minimum: const EdgeInsets.fromLTRB(
      BloomSurface.pageInset,
      BloomSurface.pageInset,
      BloomSurface.pageInset,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const BloomPageTitle(title: '我的', subtitle: '账号与登录状态'),
        const SizedBox(height: BloomPageTitle.contentGap),
        Expanded(
          child: Padding(
            // 给底部导航栏让出位置，否则内容会被玻璃条压住。
            padding: const EdgeInsets.only(bottom: 96),
            child: account == null
                ? _signedOut()
                : _signedIn(account!),
          ),
        ),
      ],
    ),
  );

  Widget _signedOut() => BloomSignInPrompt(
    key: const ValueKey('bloom-profile-signed-out'),
    title: '还没有登录',
    message: '登录后才能管理相框、手机小组件与照片。',
    onSignIn: onSignIn,
    busy: busy,
  );

  Widget _signedIn(AccountInfo account) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _accountCard(account),
        const SizedBox(height: 26),
        _signOutButton(),
        const SizedBox(height: 18),
        Text(
          '换手机登录同一个手机号即可，设备与照片都在账号里。',
          textAlign: TextAlign.center,
          style: BloomType.meta,
        ),
      ],
    ),
  );

  Widget _accountCard(AccountInfo account) => BloomPanel(
    lifted: true,
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头像位：没有头像功能，用一个首字母占位。它让这张卡片不至于只有
        // 两行字，也让"这是谁"在扫一眼时有落点。
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: BloomInk.recess,
                borderRadius: BorderRadius.circular(BloomSurface.innerRadius),
                border: Border.all(color: BloomInk.divider),
              ),
              child: Text(
                // 首字母占位。displayName 在极端情况下可能是空串
                // （phone 为空且没有昵称），characters.first 会直接抛 ——
                // 一个用于展示的角标不该有能力让整页崩掉。
                account.displayName.characters.isEmpty
                    ? '·'
                    : account.displayName.characters.first,
                style: BloomType.sectionTitle,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.displayName,
                    style: BloomType.rowTitle,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(account.maskedPhone, style: BloomType.meta),
                ],
              ),
            ),
          ],
        ),
        if (account.isProvisioning) ...[
          const SizedBox(height: 16),
          Text(
            '正在准备你的图库，稍后就能看到照片了。',
            style: BloomType.meta,
          ),
        ] else if (account.provisionFailed) ...[
          const SizedBox(height: 16),
          Text(
            '图库准备失败，请联系我们。',
            style: BloomType.meta.copyWith(color: BloomInk.accent),
          ),
        ],
      ],
    ),
  );

  Widget _signOutButton() => Center(
    child: SizedBox(
      width: 168,
      child: BloomPrimaryButton(
        key: const ValueKey('bloom-profile-sign-out'),
        label: '退出登录',
        loading: busy,
        onPressed: busy ? null : onSignOut,
      ),
    ),
  );
}
