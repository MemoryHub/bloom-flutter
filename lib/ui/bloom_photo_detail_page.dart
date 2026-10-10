import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/api/bloom_api_client.dart';
import 'bloom_glass_home.dart';
import 'bloom_discover_page.dart';
import 'bloom_photo_library_page.dart';
import 'bloom_confirmation_dialog.dart';
import 'bloom_photo_location_page.dart';

const _types = {
  0: '其他',
  1: '人物',
  2: '宠物',
  3: '风景',
  4: '日常生活',
  5: '聚会或仪式',
  6: '旅行',
  7: '食物',
  8: '建筑',
  9: '物品',
};
const _subjects = {
  1: '人物',
  2: '儿童',
  3: '老人',
  4: '宠物',
  5: '风景',
  6: '植物',
  7: '食物',
  8: '建筑',
  9: '交通工具',
  10: '物品',
};
const _moments = {
  1: '日常之美',
  2: '陪伴',
  3: '人与人互动',
  4: '调皮有趣',
  5: '温柔时刻',
  6: '成长',
  7: '团聚',
  8: '庆祝',
  9: '旅行出发',
  10: '安静时刻',
  11: '惊喜与壮美',
  12: '时间痕迹',
  13: '普通生活记录',
};
const _emotions = {
  1: '温暖',
  2: '快乐',
  3: '温柔',
  4: '平静治愈',
  5: '会心一笑',
  6: '怀旧',
  7: '惊叹',
  8: '希望',
  9: '温暖而感伤',
  10: '安静孤独',
};

class BloomPhotoDetailPage extends StatefulWidget {
  const BloomPhotoDetailPage({
    super.key,
    required this.api,
    required this.token,
    required this.photo,
  });
  final BloomApiClient api;
  final String token;
  final Map<String, dynamic> photo;
  @override
  State<BloomPhotoDetailPage> createState() => _BloomPhotoDetailPageState();
}

class _BloomPhotoDetailPageState extends State<BloomPhotoDetailPage> {
  Map<String, dynamic>? _detail, _analysis;
  late Future<Uint8List> _preview;
  final _instruction = TextEditingController();
  Timer? _poll;
  bool _busy = false, _loading = true, _changed = false;
  String? _error, _revisionMessage;
  String get _id => widget.photo['id'] as String;
  @override
  void initState() {
    super.initState();
    _preview = widget.api.photoPreview(widget.token, _id);
    unawaited(_load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await widget.api.userRequest(widget.token, 'photos/$_id');
      if (!mounted) return;
      setState(() {
        _detail = Map<String, dynamic>.from(result['photo']);
        _analysis =
            _detail!['analysis'] == null
                ? null
                : Map<String, dynamic>.from(_detail!['analysis']);
        _error = null;
        _loading = false;
      });
      final status = _analysis?['status'];
      if (status == null || status == 'pending' || status == 'processing') {
        _poll = Timer(const Duration(seconds: 5), () => unawaited(_load()));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '暂时无法读取照片信息，请重试。';
          _loading = false;
        });
      }
    }
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: BloomInk.panel,
          content: Text(text, style: BloomType.body),
        ),
      );
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    if (!await confirmBloomAction(
      context,
      title: '删除这张照片？',
      message: '照片将移入最近删除，并从之后的设备播放计划中移除。',
      confirmLabel: '删除',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    _poll?.cancel();
    try {
      await widget.api.userRequest(
        widget.token,
        'photos/$_id',
        method: 'DELETE',
      );
      if (mounted) Navigator.pop(context, {'deleted': true});
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        _notice('删除未完成，请稍后重试。');
      }
    }
  }

  Future<void> _revise() async {
    final instruction = _instruction.text.trim();
    if (_busy || instruction.isEmpty) return;
    _poll?.cancel();
    setState(() => _busy = true);
    try {
      final result = await widget.api.revisePhotoAnalysis(
        widget.token,
        _id,
        instruction,
      );
      if (!mounted) return;
      setState(() {
        _analysis = Map<String, dynamic>.from(result['analysis']);
        _revisionMessage = result['summary'] as String?;
        _changed = true;
      });
      _instruction.clear();
    } catch (_) {
      _notice('没有修改成功，原有回忆分析已保留。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() =>
      Navigator.pop(context, _changed ? {'analysis': _analysis} : null);
  Widget _text(String label, dynamic value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: BloomType.meta),
          const SizedBox(height: 6),
          SelectableText(text, style: BloomType.body),
        ],
      ),
    );
  }

  Widget _tags(String title, dynamic values, Map<int, String> labels) =>
      _compact(
        title,
        (values as List? ?? [])
            .map((e) => labels[(e as num).toInt()] ?? '')
            .where((s) => s.isNotEmpty)
            .join(' · '),
      );
  Widget _photo(double height, {bool zoom = false}) => FutureBuilder<Uint8List>(
    future: _preview,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return SizedBox(
          height: height,
          child: Center(
            child:
                snapshot.hasError
                    ? TextButton(
                      onPressed:
                          () => setState(
                            () =>
                                _preview = widget.api.photoPreview(
                                  widget.token,
                                  _id,
                                ),
                          ),
                      child: const Text('重新加载照片', style: BloomType.button),
                    )
                    : const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: BloomInk.accent,
                    ),
          ),
        );
      }
      final image = Image.memory(
        snapshot.data!,
        height: zoom ? null : height,
        fit: BoxFit.contain,
        cacheWidth: 1440,
      );
      return zoom
          ? InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(child: image),
          )
          : GestureDetector(
            onTap:
                () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder:
                        (context) => Scaffold(
                          backgroundColor: BloomInk.page,
                          appBar: AppBar(
                            backgroundColor: BloomInk.page,
                            foregroundColor: BloomInk.text,
                            title: const Text('照片', style: BloomType.pageTitle),
                          ),
                          body: SafeArea(
                            child: _photo(
                              MediaQuery.sizeOf(context).height,
                              zoom: true,
                            ),
                          ),
                        ),
                  ),
                ),
            child: image,
          );
    },
  );
  Widget _compact(String label, dynamic value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: BloomType.meta.copyWith(fontSize: 10.5)),
          const SizedBox(height: 4),
          SelectableText(
            text,
            style: BloomType.meta.copyWith(
              color: BloomInk.textMuted,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _scores() {
    final scores =
        _analysis?['scores'] as Map? ?? widget.photo['scores'] as Map? ?? {};
    return Row(
      children: [
        for (final item in [
          ('瞬间感染力', 'moment'),
          ('回味价值', 'reflection'),
          ('展示效果', 'display'),
        ])
          Expanded(
            child: Column(
              children: [
                Text(item.$1, style: BloomType.meta.copyWith(fontSize: 11)),
                const SizedBox(height: 8),
                Text(
                  scores[item.$2] == null
                      ? '—'
                      : (scores[item.$2] as num).toStringAsFixed(0),
                  style: BloomType.tileTitle.copyWith(fontSize: 30),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _analysisPanel() {
    final a = _analysis;
    if (a == null || a['status'] != 'completed') {
      return Text(
        a?['status'] == 'failed' ? '这张照片的回忆分析暂时未完成。' : '回忆分析正在准备中。',
        style: BloomType.meta,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _compact('描述', a['caption']),
        _compact('主要类型', _types[(a['primary_type'] as num? ?? 0).toInt()]),
        _tags('主体', a['subjects'], _subjects),
        _tags('瞬间', a['moment_types'], _moments),
        _tags('情绪', a['emotions'], _emotions),
        _compact('推荐状态', a['is_recommendable'] == false ? '暂不推荐' : '可推荐'),
        if ((a['sensitivity'] as num? ?? 0) > 0)
          const Text('这张照片需要谨慎展示', style: BloomType.meta),
      ],
    );
  }

  Widget _aiPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('说说照片背后的故事，或告诉 AI 想调整哪项分数。', style: BloomType.meta),
      const SizedBox(height: 14),
      TextField(
        controller: _instruction,
        enabled: !_busy,
        style: BloomType.body,
        minLines: 2,
        maxLines: 5,
        maxLength: 2000,
        decoration: InputDecoration(
          hintText: '例如：这是我们第一次全家旅行，希望回味价值调整为 85 分。',
          hintStyle: BloomType.meta,
          filled: true,
          fillColor: BloomInk.recess,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(BloomSurface.radius),
            borderSide: const BorderSide(color: BloomInk.divider),
          ),
          counterStyle: BloomType.meta,
        ),
      ),
      const SizedBox(height: 8),
      BloomPrimaryButton(
        label: _busy ? '正在理解…' : '让 AI 调整',
        onPressed: _busy ? null : _revise,
      ),
      if (_revisionMessage != null)
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(_revisionMessage!, style: BloomType.body),
        ),
    ],
  );

  Future<void> _editLocation() async {
    final info = _detail?['info'] as Map? ?? {};
    final photo = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder:
            (_) => BloomPhotoLocationPage(
              api: widget.api,
              token: widget.token,
              assetId: _id,
              latitude: (info['latitude'] as num?)?.toDouble(),
              longitude: (info['longitude'] as num?)?.toDouble(),
              locationText: _location(info),
            ),
      ),
    );
    if (!mounted || photo == null) return;
    setState(() {
      _detail = photo;
      _changed = true;
    });
  }

  String _location(Map info) {
    final named = info['location_text']?.toString().trim() ?? '';
    if (named.isNotEmpty) return named;
    final location = [
      info['country'],
      info['state'],
      info['city'],
    ].where((v) => v != null && v.toString().isNotEmpty).toSet().join(' · ');
    if (location.isNotEmpty) return location;
    if (info['latitude'] != null && info['longitude'] != null) {
      return '未识别地点';
    }
    return '未记录地点';
  }

  Widget _infoPanel() {
    final info = _detail?['info'] as Map? ?? {};
    final taken =
        DateTime.tryParse(
          '${_detail?['taken_at'] ?? widget.photo['taken_at']}',
        )?.toLocal();
    final width = info['exifImageWidth'], height = info['exifImageHeight'];
    final size = info['fileSizeInByte'] as num?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _text(
          '拍摄时间',
          taken == null
              ? '未知'
              : '${bloomPhotoDay(taken.toIso8601String())} ${taken.hour.toString().padLeft(2, '0')}:${taken.minute.toString().padLeft(2, '0')}',
        ),
        _compact('文件名', _detail?['filename'] ?? widget.photo['filename']),
        _text(
          '尺寸',
          width == null || height == null ? null : '$width × $height',
        ),
        _text(
          '文件大小',
          size == null ? null : '${(size / 1024 / 1024).toStringAsFixed(2)} MB',
        ),
        Row(
          children: [
            Expanded(child: _text('地理位置', _location(info))),
            TextButton(
              onPressed: _busy ? null : _editLocation,
              child: const Text('编辑位置', style: BloomType.button),
            ),
          ],
        ),
        _compact(
          '相机',
          [info['make'], info['model']].where((e) => e != null).join(' '),
        ),
        _compact('镜头', info['lensModel']),
        _compact('光圈', info['fNumber'] == null ? null : 'f/${info['fNumber']}'),
        _compact('快门', info['exposureTime']),
        _compact('ISO', info['iso']),
        _compact(
          '焦距',
          info['focalLength'] == null ? null : '${info['focalLength']} mm',
        ),
      ],
    );
  }

  Widget _section(String title, Widget body) => BloomPanel(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: BloomType.sectionTitle),
        const SizedBox(height: 20),
        body,
      ],
    ),
  );
  Widget _fold(String title, Widget body) => BloomPanel(
    padding: EdgeInsets.zero,
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(title, style: BloomType.sectionTitle),
        iconColor: BloomInk.textMuted,
        collapsedIconColor: BloomInk.textFaint,
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        children: [Align(alignment: Alignment.centerLeft, child: body)],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final info = _detail?['info'] as Map? ?? {};
    final caption = (_analysis?['side_caption'] as String? ?? '').trim();
    final english = (_analysis?['side_caption_en'] as String? ?? '').trim();
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: BloomInk.page,
        appBar: AppBar(
          backgroundColor: BloomInk.page,
          foregroundColor: BloomInk.text,
          leading: IconButton(
            onPressed: _busy ? null : _back,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text('照片', style: BloomType.pageTitle),
          actions: [
            IconButton(
              tooltip: '删除照片',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            BloomSurface.pageInset,
            16,
            BloomSurface.pageInset,
            MediaQuery.paddingOf(context).bottom + 32,
          ),
          children: [
            BloomExhibitionArtwork(
              api: widget.api,
              work: {
                'title': '照片',
                'image_width': info['exifImageWidth'] ?? 4,
                'image_height': info['exifImageHeight'] ?? 3,
              },
              imageBuilder: (height) => _photo(height),
            ),
            const SizedBox(height: 24),
            Text(
              caption.isEmpty ? '这一刻的回忆' : caption,
              style: BloomType.sectionTitle.copyWith(fontSize: 24, height: 1.5),
            ),
            if (english.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  english,
                  style: BloomType.body.copyWith(
                    fontFamily: 'BloomGallery',
                    color: BloomInk.textMuted,
                    fontStyle: FontStyle.italic,
                    height: 1.65,
                  ),
                ),
              ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(
                  bloomPhotoDay(
                    _detail?['taken_at'] ?? widget.photo['taken_at'],
                  ),
                  style: BloomType.meta,
                ),
                InkWell(
                  onTap: _busy ? null : _editLocation,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        size: 15,
                        color: BloomInk.textFaint,
                      ),
                      const SizedBox(width: 4),
                      Text(_location(info), style: BloomType.meta),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.edit_outlined,
                        size: 12,
                        color: BloomInk.textFaint,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if ((_analysis?['user_context'] as String? ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: BloomPanel(
                  padding: const EdgeInsets.all(16),
                  child: _text('我的记忆', _analysis!['user_context']),
                ),
              ),
            const SizedBox(height: 24),
            BloomPanel(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _scores(),
                  if ((_analysis?['reason'] as String? ?? '').isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _text('重新看见的理由', _analysis!['reason']),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            _section('用 AI 补充或调整', _aiPanel()),
            const SizedBox(height: 18),
            if (_loading)
              const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: BloomInk.accent,
                ),
              ),
            if (_error != null) ...[
              Text(_error!, style: BloomType.body),
              TextButton(
                onPressed: _load,
                child: const Text('重试', style: BloomType.button),
              ),
            ],
            _fold('回忆分析', _analysisPanel()),
            const SizedBox(height: 14),
            _fold('信息', _infoPanel()),
          ],
        ),
      ),
    );
  }
}
