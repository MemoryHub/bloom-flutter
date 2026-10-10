import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/widget_bridge.dart';
import 'bloom_glass_home.dart';

/// 「本机后台保活」自检卡片。
///
/// **它只说自己这台手机的事**，所以它出现在「手机小组件」那台设备的详情页里，
/// 而不是设备列表——它是这台手机的属性，不是某个服务端设备的属性。
///
/// 四条设计原则，都来自用户对这类提示的反感：
///
///   1. **不适用就不出现。** 整个列表由原生按机型和系统版本推导：小米5
///      （Android 8）不会出现「精确闹钟」项，非小米机型不会出现「自启动」项，
///      iOS 上三项全不适用 → 原生直接返回空列表 → 这张卡片**整个不渲染**。
///   2. **读不到的必须能收尾。** 小米自启动的状态第三方拿不到，那一项
///      `satisfied == null`。如果把它一直算作「待开启」，用户开完开关回来
///      仍然看到「1 项待开启」——那是个永远没有终点的提示。所以这种项走
///      「去确认 → 我已开启」两步，确认后本地记住、不再计入。
///   3. **全部就绪就闭嘴。** 只剩一行「已全部就绪」，不列条目、不催。
///   4. **绝不假装。** 确认是**用户的声明**，不是我们探测到的事实，所以只用
///      在系统根本不提供查询的那一项上；能查的两项一律以系统返回为准。
class BloomKeepAliveCard extends StatefulWidget {
  const BloomKeepAliveCard({super.key});

  @override
  State<BloomKeepAliveCard> createState() => _BloomKeepAliveCardState();
}

class _BloomKeepAliveCardState extends State<BloomKeepAliveCard>
    with WidgetsBindingObserver {
  List<KeepAliveItem>? _items;
  bool _busy = false;

  /// 已经跳过去看过设置页的项（跳转失败、就地显示文字步骤的也记在这里）。
  final Set<String> _visited = {};

  /// 跳转失败、就地展开文字步骤的项。
  final Set<String> _revealedSteps = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// **从系统设置页回来时重新检查。** 用户刚去开了开关，回来就该看到变化；
  /// 否则他会以为没生效，再点一次。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _load();
  }

  Future<void> _load() async {
    List<KeepAliveItem> items;
    try {
      items = await WidgetBridge().keepAliveStatus();
    } catch (_) {
      // 拿不到就当没有这项功能，不要因为一个提示卡片影响整页。
      items = const [];
    }
    if (!mounted) return;
    setState(() => _items = items);
  }

  Future<void> _open(KeepAliveItem item) async {
    if (_busy) return;
    setState(() => _busy = true);
    var opened = false;
    try {
      opened = await WidgetBridge().openKeepAlive(item.id);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _visited.add(item.id);
      if (!opened && item.steps != null) {
        // 跳不过去就把路写清楚——**点了没反应比没有这个按钮更糟**。
        _revealedSteps.add(item.id);
      }
    });
    if (opened) unawaited(_load());
  }

  Future<void> _acknowledge(KeepAliveItem item) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await WidgetBridge().acknowledgeKeepAlive(item.id);
    } catch (_) {
      // 记不住就下次再问，不影响主流程。
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    // iOS / 老系统 / 非小米：没有任何适用项，整张卡片不存在。
    if (items == null || items.isEmpty) return const SizedBox.shrink();

    final pending = items.where((item) => item.satisfied != true).toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: BloomInk.panel,
        borderRadius: BorderRadius.circular(BloomSurface.radius),
        border: Border.all(color: BloomInk.controlEdge),
        boxShadow: BloomInk.lift,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                pending.isEmpty
                    ? Icons.check_circle_outline_rounded
                    : Icons.shield_outlined,
                size: 15,
                color: pending.isEmpty ? BloomInk.accent : BloomInk.textMuted,
              ),
              const SizedBox(width: 7),
              Text('后台保活', style: BloomType.labelStrong),
              const Spacer(),
              Text(
                pending.isEmpty ? '已全部就绪' : '${pending.length} 项待开启',
                style: BloomType.label.copyWith(
                  color: pending.isEmpty ? BloomInk.accent : BloomInk.textMuted,
                ),
              ),
            ],
          ),
          // 全部就绪时**只留一行**：这一页的设计原则是不要解释文字，
          // 状态确认可以留，说教不要。
          if (pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '开启后，即使不打开 App，小组件也能自己换图。',
                style: BloomType.label.copyWith(color: BloomInk.textFaint),
              ),
            ),
          for (final item in pending) _row(item),
        ],
      ),
    );
  }

  Widget _row(KeepAliveItem item) {
    final revealed = _revealedSteps.contains(item.id) || item.needsAck;
    // 读不到状态、且用户已经去看过设置页：给一个「我已开启」收尾，
    // 否则这一项会永远停在「待开启」。
    final askConfirm = item.needsAck && _visited.contains(item.id);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, style: BloomType.label),
                    const SizedBox(height: 2),
                    Text(
                      item.why,
                      style: BloomType.label.copyWith(
                        color: BloomInk.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _button(
                // 读不到状态时说「去确认」而不是「去开启」——措辞上不替系统下结论。
                label: item.canOpen
                    ? (item.needsAck ? '去确认' : '去开启')
                    : '查看步骤',
                onTap: () => _open(item),
              ),
            ],
          ),
          if (revealed && item.steps != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                item.steps!,
                style: BloomType.label.copyWith(color: BloomInk.accent),
              ),
            ),
          if (askConfirm)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '系统不提供这项状态的查询，开好了请点右边',
                      style: BloomType.label.copyWith(
                        color: BloomInk.textFaint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _button(label: '我已开启', onTap: () => _acknowledge(item)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _button({required String label, required VoidCallback onTap}) =>
      GestureDetector(
        onTap: _busy ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(BloomSurface.controlRadius),
            border: Border.all(color: BloomInk.controlEdge),
          ),
          child: Text(
            label,
            style: BloomType.label.copyWith(color: BloomInk.accent),
          ),
        ),
      );
}
