import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/api/bloom_api_client.dart';
import '../core/rendering/mobile_artwork_renderer.dart';
import 'bloom_glass_home.dart';

const _paper = BloomInk.page;
const _ink = BloomInk.text;
const _muted = BloomInk.textMuted;
const _headline = TextStyle(
  fontFamily: BloomType.serifFamily,
  fontFamilyFallback: BloomType.serifFallback,
  color: _ink,
  fontSize: 34,
  height: 1.18,
);
const _prose = TextStyle(
  fontFamily: BloomType.serifFamily,
  fontFamilyFallback: BloomType.serifFallback,
  color: _muted,
  fontSize: 15,
  height: 1.7,
);

String galleryArtworkText(
  Map<String, dynamic> data,
  String field, {
  String language = 'zh-CN',
}) {
  final translations = data['app_translations'];
  if (translations is Map) {
    final translated = translations[language];
    if (translated is Map &&
        translated[field] is String &&
        (translated[field] as String).trim().isNotEmpty) {
      return translated[field] as String;
    }
  }
  return data[field] as String? ?? '';
}

final _textButtonStyle = TextButton.styleFrom(
  foregroundColor: _ink,
  textStyle: BloomType.button,
);

final _primaryDialogStyle = FilledButton.styleFrom(
  backgroundColor: BloomInk.accent,
  foregroundColor: BloomInk.inverseInk,
  textStyle: BloomType.button,
);

String galleryArtistNationality(Map<String, dynamic> work) {
  const countries = {
    'JP': '日本',
    'NL': '荷兰',
    'FR': '法国',
    'AT': '奥地利',
    'IT': '意大利',
    'GB': '英国',
    'US': '美国',
    'DE': '德国',
    'ES': '西班牙',
    'UA': '乌克兰',
  };
  final country = countries[work['artist_country_code']];
  if (country != null) return country;
  final translated = galleryArtworkText(work, 'artist_nationality');
  if (translated == 'Netherlandish') return '尼德兰地区';
  return translated;
}

class _ArtistNationality extends StatelessWidget {
  const _ArtistNationality(this.work);
  final Map<String, dynamic> work;
  @override
  Widget build(BuildContext context) {
    final country = work['artist_country_code'] as String? ?? '';
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        if (const [
          'JP',
          'NL',
          'FR',
          'AT',
          'IT',
          'GB',
          'US',
          'DE',
          'ES',
          'UA',
        ].contains(country))
          ExcludeSemantics(
            child: ClipRect(
              child: CustomPaint(
                size: const Size(18, 12),
                painter: _CountryFlagPainter(country),
              ),
            ),
          ),
        Text(galleryArtistNationality(work), style: BloomType.meta),
      ],
    );
  }
}

class _CountryFlagPainter extends CustomPainter {
  const _CountryFlagPainter(this.country);
  final String country;
  @override
  void paint(Canvas canvas, Size size) => MobileArtworkRenderer.drawFlag(
    canvas,
    GalleryFlag(country, Offset.zero & size),
  );
  @override
  bool shouldRepaint(_CountryFlagPainter oldDelegate) =>
      country != oldDelegate.country;
}

Future<bool> _confirmSend(
  BuildContext context,
  GalleryFrame frame,
  String kind,
) async =>
    await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: BloomInk.panel,
            title: Text(
              kind == 'collection' ? '把这个展览送过去？' : '把这幅作品送过去？',
              style: BloomType.rowTitle,
            ),
            content: Text(
              '发送到「${frame.name}」，按设备原来的时间安排播放。所有绑定这台设备的家人都会看到同一份播放内容。',
              style: _prose,
            ),
            actions: [
              TextButton(
                style: _textButtonStyle,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('再看看'),
              ),
              FilledButton(
                style: _primaryDialogStyle,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认发送'),
              ),
            ],
          ),
    ) ??
    false;

String _removalMessage(String kind) =>
    kind == 'collection'
        ? '已取消，等待设备同步。单独发送或来自其他展览的作品仍会播放。'
        : '已取消，等待设备同步。若仍属于已发送的展览，这幅画仍会播放。';

Future<bool> _confirmRemoval(
  BuildContext context,
  String deviceName,
  String kind, {
  bool inherited = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: BloomInk.panel,
            title: Text(
              kind == 'collection' ? '取消发送这个展览？' : '取消单独发送这幅作品？',
              style: BloomType.rowTitle,
            ),
            content: Text(
              kind == 'collection'
                  ? '将从「$deviceName」的播放内容中移除这个展览。单独发送或来自其他展览的作品仍会保留；已缓存的内容可能继续显示，后续计划会使用新选择。'
                  : inherited
                  ? '取消向「$deviceName」单独发送这幅作品。它仍在已发送的展览中，因此会继续播放；如需停止，请到对应展览页取消发送。'
                  : '将从「$deviceName」的播放内容中移除这幅作品。已缓存的内容可能继续显示，后续计划会使用新选择。',
              style: _prose,
            ),
            actions: [
              TextButton(
                style: _textButtonStyle,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保留'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BloomInk.offline,
                  foregroundColor: BloomInk.text,
                  textStyle: BloomType.button,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认取消'),
              ),
            ],
          ),
    ) ??
    false;

class GalleryFrame {
  const GalleryFrame(
    this.id,
    this.name, {
    this.supportsArt = true,
    this.isMobile = false,
  });
  final String id;
  final String name;
  final bool supportsArt;
  final bool isMobile;
}

class GallerySession {
  const GallerySession({
    required this.token,
    required this.frames,
    this.onContentChanged,
  });
  final Future<void> Function(String deviceId)? onContentChanged;
  final String? Function() token;
  final List<GalleryFrame> Function() frames;
}

class BloomDiscoverPage extends StatefulWidget {
  const BloomDiscoverPage({
    super.key,
    required this.api,
    required this.frames,
    this.userToken,
    this.session,
    this.onSignIn,
  });
  final BloomApiClient api;
  final List<GalleryFrame> frames;
  final String? userToken;
  final GallerySession? session;
  final VoidCallback? onSignIn;
  @override
  State<BloomDiscoverPage> createState() => _BloomDiscoverPageState();
}

class _BloomDiscoverPageState extends State<BloomDiscoverPage> {
  final List<Map<String, dynamic>> _collections = [];
  bool _loading = false, _more = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.discoverCollections(
        offset: reset ? 0 : _collections.length,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _collections.clear();
        _collections.addAll(
          (data['items'] as List).cast<Map<String, dynamic>>(),
        );
        _more = data['has_more'] == true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法打开展览，请稍后重试。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

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
        const BloomPageTitle(title: '发现'),
        const SizedBox(height: BloomPageTitle.contentGap),
        Expanded(
          child: RefreshIndicator(
            color: BloomInk.accent,
            onRefresh: () => _load(reset: true),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 120),
              children: [
                const Text('把艺术带回家', style: _headline),
                const SizedBox(height: 14),
                const Text('给熟悉的日常，留一点艺术的位置。', style: _prose),
                const SizedBox(height: 36),
                for (final c in _collections)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: InkWell(
                      onTap:
                          () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder:
                                  (_) => _CollectionPage(
                                    collection: c,
                                    api: widget.api,
                                    frames: widget.frames,
                                    userToken: widget.userToken,
                                    session: widget.session,
                                    onSignIn: widget.onSignIn,
                                  ),
                            ),
                          ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GalleryImage(
                            api: widget.api,
                            path: (c['cover'] as Map)['image_url'] as String,
                            height: 280,
                          ),
                          const SizedBox(height: 18),
                          Text(
                            '${c['work_count']} 幅作品 · Bloom 展览',
                            style: const TextStyle(
                              fontFamily: BloomType.serifFamily,
                              fontFamilyFallback: BloomType.serifFallback,
                              color: _muted,
                              fontSize: 10,
                              letterSpacing: 1.6,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            c['title'] as String,
                            style: _headline.copyWith(fontSize: 27),
                          ),
                          const SizedBox(height: 10),
                          Text(c['subtitle'] as String? ?? '', style: _prose),
                          const SizedBox(height: 16),
                          const Row(
                            children: [
                              Text(
                                '走进展览',
                                style: TextStyle(
                                  fontFamily: BloomType.serifFamily,
                                  fontFamilyFallback: BloomType.serifFallback,
                                  color: _ink,
                                  fontSize: 13,
                                ),
                              ),
                              SizedBox(width: 8),
                              Icon(Icons.arrow_forward, size: 16, color: _ink),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_error != null)
                  _Retry(message: _error!, onRetry: () => _load(reset: true)),
                if (!_loading && _error == null && _collections.isEmpty)
                  const Text('新的展览正在准备中。', style: _prose),
                if (_loading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (_more && !_loading && _collections.isNotEmpty)
                  TextButton(
                    style: _textButtonStyle,
                    onPressed: _load,
                    child: const Text('更多展览'),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class GalleryImage extends StatelessWidget {
  const GalleryImage({
    super.key,
    required this.api,
    required this.path,
    this.height = 300,
  });
  final BloomApiClient api;
  final String path;
  final double height;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: Image.network(
      api.discoverImageUrl(path),
      fit: BoxFit.contain,
      frameBuilder:
          (context, child, frame, synchronous) =>
              synchronous || frame != null
                  ? child
                  : const _GalleryImagePlaceholder(),
      loadingBuilder:
          (context, child, loading) =>
              loading == null ? child : const _GalleryImagePlaceholder(),
      errorBuilder:
          (context, error, stack) =>
              const _GalleryImagePlaceholder(failed: true),
    ),
  );
}

class _GalleryImagePlaceholder extends StatelessWidget {
  const _GalleryImagePlaceholder({this.failed = false});
  final bool failed;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey(failed ? 'gallery-image-error' : 'gallery-image-loading'),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: BloomInk.panel,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: BloomInk.divider),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          failed ? Icons.image_not_supported_outlined : Icons.image_outlined,
          size: 30,
          color: BloomInk.textFaint,
        ),
        const SizedBox(height: 12),
        Text(
          failed ? '图片暂时无法加载' : '作品加载中',
          style: const TextStyle(
            fontFamily: BloomType.serifFamily,
            fontFamilyFallback: BloomType.serifFallback,
            color: _muted,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

class _GalleryJoinBar extends StatelessWidget {
  const _GalleryJoinBar({required this.onJoin, required this.label});
  final String label;
  final VoidCallback onJoin;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: BloomInk.panel,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BloomSurface.pageInset,
          12,
          BloomSurface.pageInset,
          12,
        ),
        child: BloomPrimaryButton(
          key: const ValueKey('gallery-join-frame'),
          label: label,
          onPressed: onJoin,
        ),
      ),
    ),
  );
}

class _CollectionPage extends StatefulWidget {
  const _CollectionPage({
    required this.collection,
    required this.api,
    required this.frames,
    this.userToken,
    this.session,
    this.onSignIn,
  });
  final Map<String, dynamic> collection;
  final BloomApiClient api;
  final List<GalleryFrame> frames;
  final String? userToken;
  final GallerySession? session;
  final VoidCallback? onSignIn;
  @override
  State<_CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<_CollectionPage> {
  final ScrollController _scroll = ScrollController();
  final List<Map<String, dynamic>> _works = [];
  bool _more = true, _loading = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadNearEnd);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _loadNearEnd() {
    if (mounted &&
        _scroll.hasClients &&
        _scroll.position.extentAfter < 1000 &&
        _more &&
        !_loading &&
        _error == null) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.discoverCollection(
        widget.collection['id'] as String,
        offset: _works.length,
      );
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      if (items.isEmpty && data['has_more'] == true) {
        throw StateError('Empty page with more works');
      }
      if (mounted) {
        setState(() {
          _works.addAll(items);
          _more = data['has_more'] == true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '作品暂时没有加载成功。');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _loadNearEnd());
      }
    }
  }

  void _joinCollection() => _join(
    context,
    widget.api,
    widget.session?.frames() ?? widget.frames,
    widget.session == null ? widget.userToken : widget.session!.token(),
    widget.onSignIn,
    'collection',
    widget.collection['id'] as String,
    widget.session?.onContentChanged,
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(
      backgroundColor: _paper,
      surfaceTintColor: Colors.transparent,
      foregroundColor: _ink,
      centerTitle: false,
      title: const Text('展览', style: BloomType.pageTitle),
    ),
    bottomNavigationBar: _GalleryJoinBar(
      onJoin: _joinCollection,
      label: '发送整个展览到设备',
    ),
    body: BloomAtmosphere(
      child: ListView.builder(
        key: const ValueKey('gallery-collection-scroll'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(26, 30, 26, 60),
        itemCount: _works.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.collection['title'] as String,
                  style: _headline.copyWith(fontSize: 32),
                ),
                const SizedBox(height: 24),
                Text(
                  widget.collection['introduction'] as String? ?? '',
                  style: _prose,
                ),
                const SizedBox(height: 32),
                Text(
                  '${widget.collection['work_count']} 幅作品 · 一场日常里的小展览',
                  style: const TextStyle(
                    fontFamily: BloomType.serifFamily,
                    fontFamilyFallback: BloomType.serifFallback,
                    color: _muted,
                    fontSize: 10,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 40),
              ],
            );
          }
          if (index <= _works.length) {
            final work = _works[index - 1];
            return _EditorialWork(
              work: work,
              api: widget.api,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder:
                          (_) => _ArtworkPage(
                            work: work,
                            api: widget.api,
                            frames: widget.frames,
                            userToken: widget.userToken,
                            session: widget.session,
                            onSignIn: widget.onSignIn,
                          ),
                    ),
                  ),
            );
          }
          return Column(
            children: [
              if (_loading)
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              if (_error != null) _Retry(message: _error!, onRetry: _load),
              if (_more && !_loading && _error == null)
                TextButton(
                  style: _textButtonStyle,
                  onPressed: _load,
                  child: const Text('加载更多作品'),
                ),
              if (!_more)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Text(
                    '让艺术，慢慢融入日常。',
                    style: _prose,
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _EditorialWork extends StatelessWidget {
  const _EditorialWork({
    required this.work,
    required this.api,
    required this.onTap,
  });
  final Map<String, dynamic> work;
  final BloomApiClient api;
  final VoidCallback onTap;

  Widget _copy({required bool beside}) => Column(
    key: ValueKey('gallery-copy-${work['id']}'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        galleryArtworkText(work, 'title'),
        style: _headline.copyWith(fontSize: beside ? 21 : 25),
      ),
      const SizedBox(height: 10),
      Text(
        [
          galleryArtworkText(work, 'artist'),
          work['year'] as String? ?? '',
        ].where((s) => s.isNotEmpty).join(' / '),
        style: BloomType.meta,
      ),
      if (galleryArtistNationality(work).isNotEmpty) ...[
        const SizedBox(height: 6),
        _ArtistNationality(work),
      ],
      const SizedBox(height: 14),
      Text(
        galleryArtworkText(work, 'short_description'),
        style: _prose.copyWith(fontSize: beside ? 13 : 15),
        maxLines: beside ? 7 : null,
        overflow: beside ? TextOverflow.ellipsis : null,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final position = (work['position'] as num).toInt();
    final pattern = position % 3;
    return Padding(
      padding: EdgeInsets.only(top: pattern == 2 ? 24 : 0, bottom: 48),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment:
              pattern == 1 ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text('${position + 1}'.padLeft(2, '0'), style: BloomType.label),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final centered = pattern == 2;
                final imageWidth =
                    centered
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 18) * .57;
                final aspect =
                    (work['image_width'] as num? ?? 4) /
                    (work['image_height'] as num? ?? 3);
                final height = (imageWidth / (aspect > 0 ? aspect : 1)).clamp(
                  130.0,
                  centered ? 350.0 : 320.0,
                );
                final image = GalleryImage(
                  key: ValueKey('gallery-image-${work['id']}'),
                  api: api,
                  path: work['image_url'] as String,
                  height: height,
                );
                if (centered) {
                  return Column(
                    children: [
                      image,
                      const SizedBox(height: 22),
                      _copy(beside: false),
                    ],
                  );
                }
                final picture = SizedBox(width: imageWidth, child: image);
                final copy = Expanded(child: _copy(beside: true));
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children:
                      pattern == 1
                          ? [copy, const SizedBox(width: 18), picture]
                          : [picture, const SizedBox(width: 18), copy],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Adaptive gallery staging: the frame fits the original, including tall canvases.
/// Reference: Canson's exhibition hanging guide; all wall and lighting geometry
/// is drawn here, so no third-party stock photograph is bundled in the app.
class BloomExhibitionArtwork extends StatelessWidget {
  const BloomExhibitionArtwork({
    super.key,
    required this.api,
    required this.work,
    this.imageBuilder,
  });
  final Widget Function(double height)? imageBuilder;
  final BloomApiClient api;
  final Map<String, dynamic> work;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sourceW = (work['image_width'] as num? ?? 4).toDouble();
      final sourceH = (work['image_height'] as num? ?? 3).toDouble();
      final aspect = sourceW > 0 && sourceH > 0 ? sourceW / sourceH : 4 / 3;
      final available = constraints.maxWidth - 58;
      final height = (available / aspect).clamp(80.0, 350.0);
      final width = (height * aspect).clamp(40.0, available);
      return Semantics(
        label: '展厅中的${galleryArtworkText(work, 'title')}',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: CustomPaint(
            painter: _GalleryWallPainter(),
            foregroundPainter: _ArtworkSpotlightPainter(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(29, 88, 29, 48),
              child: Center(
                child: Container(
                  width: width + 12,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xff545049),
                        Color(0xff282824),
                        Color(0xff48453e),
                      ],
                    ),
                    border: Border.all(
                      color: const Color(0xff262622),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .23),
                        blurRadius: 16,
                        spreadRadius: 1,
                        offset: const Offset(5, 10),
                      ),
                    ],
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(1.5),
                    color: const Color(0xffbbb6a9),
                    child:
                        imageBuilder?.call(height) ??
                        GalleryImage(
                          api: api,
                          path: work['image_url'] as String,
                          height: height,
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _GalleryWallPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final wall = Offset.zero & size;
    canvas.drawRect(
      wall,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xffb9b5ab), Color(0xffd9d5ca), Color(0xffc8c3b7)],
        ).createShader(wall),
    );
    // Defined cones on the wall; a softer separate layer falls on the artwork.
    for (final fraction in [.24, .5, .76]) {
      final x = size.width * fraction;
      final reach = size.height * .72;
      final spread = size.width * .19;
      final beam =
          Path()
            ..moveTo(x - 3, 39)
            ..lineTo(x - spread, reach)
            ..quadraticBezierTo(x, reach + 16, x + spread, reach)
            ..lineTo(x + 3, 39)
            ..close();
      canvas.drawPath(
        beam,
        Paint()
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xfffff5da).withValues(alpha: .86),
              const Color(0xfffffaec).withValues(alpha: .42),
              const Color(0xfffffaec).withValues(alpha: 0),
            ],
            stops: const [0, .58, 1],
          ).createShader(Rect.fromLTRB(x - spread, 39, x + spread, reach + 16)),
      );
      final light = Rect.fromCenter(
        center: Offset(x, size.height * .47),
        width: size.width * .85,
        height: size.height * 1.22,
      );
      canvas.drawOval(
        light,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xfffff9e7).withValues(alpha: .12),
              const Color(0xfffffaec).withValues(alpha: 0),
            ],
          ).createShader(light),
      );
    }
    canvas.drawLine(
      const Offset(18, 22),
      Offset(size.width - 18, 22),
      Paint()
        ..color = const Color(0xffaaa69c)
        ..strokeWidth = 1.4,
    );
    for (final fraction in [.24, .5, .76]) {
      final x = size.width * fraction;
      canvas.drawLine(
        Offset(x, 22),
        Offset(x, 30),
        Paint()
          ..color = const Color(0xff736f66)
          ..strokeWidth = 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, 34), width: 13, height: 10),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xff605d56),
      );
      canvas.drawLine(
        Offset(x - 4, 39),
        Offset(x + 4, 39),
        Paint()
          ..color = const Color(0xfff8e6b8)
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GalleryWallPainter oldDelegate) => false;
}

class _ArtworkSpotlightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // A subtle light on the framed work. Keep the original fully visible;
    // the beams are static, so the exhibition does not need an animation loop.
    final painting = Rect.fromLTRB(29, 88, size.width - 29, size.height - 48);
    if (painting.isEmpty) return;
    canvas.save();
    canvas.clipRect(painting);
    for (final fraction in [.24, .5, .76]) {
      final glow = Rect.fromCenter(
        center: Offset(size.width * fraction, 110),
        width: size.width * .55,
        height: painting.height * .65,
      );
      canvas.drawOval(
        glow,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xfffff9e7).withValues(alpha: .18),
              const Color(0xfffff9e7).withValues(alpha: 0),
            ],
          ).createShader(glow),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ArtworkSpotlightPainter oldDelegate) => false;
}

class _ArtworkPage extends StatelessWidget {
  const _ArtworkPage({
    required this.work,
    required this.api,
    required this.frames,
    this.userToken,
    this.session,
    this.onSignIn,
  });
  final Map<String, dynamic> work;
  final BloomApiClient api;
  final List<GalleryFrame> frames;
  final String? userToken;
  final GallerySession? session;
  final VoidCallback? onSignIn;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(
      backgroundColor: _paper,
      surfaceTintColor: Colors.transparent,
      foregroundColor: _ink,
    ),
    bottomNavigationBar: _GalleryJoinBar(
      label: '发送这幅作品到设备',
      onJoin:
          () => _join(
            context,
            api,
            session?.frames() ?? frames,
            session == null ? userToken : session!.token(),
            onSignIn,
            'artwork',
            work['id'] as String,
            session?.onContentChanged,
          ),
    ),
    body: BloomAtmosphere(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(26, 20, 26, 60),
        children: [
          BloomExhibitionArtwork(api: api, work: work),
          const SizedBox(height: 24),
          if ((work['bloom_note_zh'] as String? ?? '').isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
              decoration: BoxDecoration(
                color: BloomInk.panel,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: BloomInk.divider),
              ),
              child: Text(
                work['bloom_note_zh'] as String,
                style: _prose.copyWith(color: _ink, height: 1.8),
              ),
            ),
            const SizedBox(height: 14),
          ],
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: BloomInk.panel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: BloomInk.divider),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .035),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  galleryArtworkText(work, 'title'),
                  style: _headline.copyWith(fontSize: 28),
                ),
                const SizedBox(height: 12),
                Text(
                  [
                    galleryArtworkText(work, 'artist'),
                    (work['year'] as String? ?? ''),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: BloomType.meta,
                ),
                if (galleryArtistNationality(work).isNotEmpty) ...[
                  const SizedBox(height: 7),
                  _ArtistNationality(work),
                ],
                const SizedBox(height: 22),
                Text(
                  galleryArtworkText(work, 'story').isNotEmpty
                      ? galleryArtworkText(work, 'story')
                      : galleryArtworkText(work, 'short_description'),
                  style: _prose,
                ),
                if (galleryArtworkText(work, 'medium').isNotEmpty) ...[
                  const SizedBox(height: 22),
                  Text(
                    galleryArtworkText(work, 'medium'),
                    style: BloomType.meta,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _join(
  BuildContext context,
  BloomApiClient api,
  List<GalleryFrame> frames,
  String? token,
  VoidCallback? onSignIn,
  String kind,
  String id, [
  Future<void> Function(String deviceId)? onContentChanged,
]) async {
  if (token == null || token.trim().isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('登录后，可以把展览或作品发送到你的设备。', style: _prose)),
    );
    onSignIn?.call();
    return;
  }
  if (frames.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('请先在设备页绑定相框或手机小组件。', style: _prose)),
    );
    return;
  }
  final sheetController = DraggableScrollableController();
  try {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: BloomInk.panel,
      isScrollControlled: true,
      showDragHandle: true,
      enableDrag: true,
      isDismissible: true,
      builder:
          (_) => DraggableScrollableSheet(
            controller: sheetController,
            expand: false,
            initialChildSize: .62,
            minChildSize: .24,
            maxChildSize: .9,
            builder:
                (_, controller) => _SelectionSheet(
                  scrollController: controller,
                  sheetController: sheetController,
                  api: api,
                  frames: frames,
                  token: token,
                  kind: kind,
                  contentId: id,
                  onContentChanged: onContentChanged,
                ),
          ),
    );
  } finally {
    sheetController.dispose();
  }
}

class _SelectionSheet extends StatefulWidget {
  const _SelectionSheet({
    required this.api,
    required this.frames,
    required this.token,
    required this.kind,
    required this.contentId,
    this.onContentChanged,
    required this.scrollController,
    required this.sheetController,
  });
  final ScrollController scrollController;
  final DraggableScrollableController sheetController;
  final Future<void> Function(String deviceId)? onContentChanged;
  final BloomApiClient api;
  final List<GalleryFrame> frames;
  final String token, kind, contentId;
  @override
  State<_SelectionSheet> createState() => _SelectionSheetState();
}

class _SelectionSheetState extends State<_SelectionSheet>
    with WidgetsBindingObserver {
  final Map<String, bool> _selected = {};
  final Map<String, bool> _direct = {};
  final Map<String, List<Map<String, dynamic>>> _parents = {};
  String? _busy, _message;
  bool _loading = false, _foreground = true;
  Timer? _refresh;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_foreground && _busy == null) _load();
    });
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && _busy == null) _load();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _busy != null) return;
    _loading = true;
    try {
      for (final frame in widget.frames) {
        if (!frame.supportsArt) continue;
        try {
          final data = await widget.api.contentSelections(
            widget.token,
            frame.id,
          );
          if (mounted && _busy == null) {
            setState(() {
              final previous = _selected[frame.id];
              final direct = _direct[frame.id];
              _applySelection(frame.id, data);
              if (previous != null &&
                  (previous != _selected[frame.id] ||
                      direct != _direct[frame.id])) {
                _message = '这台设备的播放内容已更新，已同步最新状态。';
              }
            });
          }
        } catch (_) {
          if (mounted && _busy == null && !_selected.containsKey(frame.id)) {
            setState(() => _message = '暂时无法读取设备设置，请重试。');
          }
        }
      }
    } finally {
      _loading = false;
    }
  }

  void _applySelection(String deviceId, Map<String, dynamic> data) {
    final direct = (data['items'] as List? ?? []).any(
      (dynamic s) => s['kind'] == widget.kind && s['id'] == widget.contentId,
    );
    final origins = data['artwork_origins'] as Map?;
    final origin = origins?[widget.contentId] as Map?;
    _direct[deviceId] = direct;
    _parents[deviceId] =
        ((origin?['collections'] as List?) ?? [])
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList();
    _selected[deviceId] =
        direct ||
        (widget.kind == 'artwork' &&
            ((data['effective_artwork_ids'] as List? ?? []).contains(
              widget.contentId,
            )));
  }

  Future<void> _toggle(GalleryFrame frame) async {
    if (_busy != null || !_selected.containsKey(frame.id)) return;
    final wasSelected = _selected[frame.id];
    final wasDirect = _direct[frame.id];
    setState(() {
      _busy = frame.id;
      _message = null;
    });
    try {
      final latest = await widget.api.contentSelections(widget.token, frame.id);
      if (!mounted) return;
      setState(() => _applySelection(frame.id, latest));
      // Keep the user's original action. A refreshed state must never turn a
      // stale "send" tap into cancellation, or a cancellation into a new send.
      if (wasSelected != _selected[frame.id] ||
          wasDirect != _direct[frame.id]) {
        setState(
          () =>
              _message =
                  _selected[frame.id] == true
                      ? '家人已发送到这台设备，状态已更新，无需重复发送。'
                      : '这台设备的播放内容已更新，请按最新状态操作。',
        );
        return;
      }
      final parents = _parents[frame.id] ?? [];
      if (_selected[frame.id] == true && _direct[frame.id] != true) {
        await showDialog<void>(
          context: context,
          builder:
              (context) => AlertDialog(
                backgroundColor: BloomInk.panel,
                title: const Text('这幅作品已发送', style: BloomType.rowTitle),
                content: Text(
                  '已通过${parents.map((p) => '「${p['title']}」').join('、')}发送到「${frame.name}」。无需重复发送；如需停止，请在对应展览页取消发送。',
                  style: _prose,
                ),
                actions: [
                  TextButton(
                    style: _textButtonStyle,
                    onPressed: () => Navigator.pop(context),
                    child: const Text('知道了'),
                  ),
                ],
              ),
        );
        return;
      }
      if (!mounted) return;
      final next = _direct[frame.id] != true;
      final confirmed =
          await (next
              ? _confirmSend(context, frame, widget.kind)
              : _confirmRemoval(
                context,
                frame.name,
                widget.kind,
                inherited: parents.isNotEmpty,
              ));
      if (!confirmed || !mounted) return;
      final checked = await widget.api.contentSelections(
        widget.token,
        frame.id,
      );
      if (!mounted) return;
      setState(() => _applySelection(frame.id, checked));
      if (next && _selected[frame.id] == true ||
          !next && _direct[frame.id] != true) {
        setState(() => _message = next ? '家人已发送到这台设备，无需重复发送。' : '已取消发送，状态已同步。');
        return;
      }
      Future<Map<String, dynamic>> save() => widget.api.changeContentSelection(
        widget.token,
        frame.id,
        kind: widget.kind,
        referenceId: widget.contentId,
        selected: next,
      );
      final reduceMotion = MediaQuery.of(context).disableAnimations;
      final response =
          await (next
              ? showDialog<Map<String, dynamic>>(
                context: context,
                barrierDismissible: false,
                builder:
                    (_) => _SendingDialog(
                      frame: frame,
                      kind: widget.kind,
                      save: save,
                      reduceMotion: reduceMotion,
                    ),
              )
              : save());
      if (response == null) return;
      if (mounted) {
        setState(() {
          if (response.containsKey('effective_artwork_ids')) {
            _applySelection(frame.id, response);
          } else {
            _direct[frame.id] = next;
            _selected[frame.id] = next;
          }
          _message = next ? null : _removalMessage(widget.kind);
        });
      }
      try {
        await widget.onContentChanged?.call(frame.id);
      } catch (error) {
        debugPrint('[BloomGallery] next sync will retry: $error');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = '暂时无法确认保存结果，请刷新状态后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 30),
      child: ListView(
        controller: widget.scrollController,
        children: [
          Row(
            children: [
              const Expanded(child: Text('选择展示设备', style: BloomType.pageTitle)),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close, color: _ink),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            widget.kind == 'collection'
                ? '发送展览中的全部作品，按设备原来的时间安排播放。'
                : '只发送这幅作品，按设备原来的时间安排播放。',
            style: _prose,
          ),
          const SizedBox(height: 20),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(_message!, style: _prose),
            ),
          for (final frame in widget.frames)
            ListTile(
              enabled: frame.supportsArt,
              contentPadding: EdgeInsets.zero,
              subtitle: Text(
                '${frame.isMobile ? '手机小组件' : '墨水屏相框'}${(_parents[frame.id] ?? []).isNotEmpty ? '\n${_direct[frame.id] == true ? '单独发送 · ' : ''}来自展览：${_parents[frame.id]!.map((p) => p['title']).join('、')}' : ''}',
                style: BloomType.meta,
              ),
              title: Text(
                frame.name,
                style: const TextStyle(
                  fontFamily: BloomType.serifFamily,
                  fontFamilyFallback: BloomType.serifFallback,
                  color: _ink,
                ),
              ),
              trailing:
                  !frame.supportsArt
                      ? const Text('暂不支持', style: BloomType.meta)
                      : _busy == frame.id
                      ? const Text('请稍候', style: BloomType.meta)
                      : !_selected.containsKey(frame.id)
                      ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 1),
                      )
                      : Text(
                        _selected[frame.id]! ? '已发送 ✓' : '发送',
                        style: const TextStyle(
                          fontFamily: BloomType.serifFamily,
                          fontFamilyFallback: BloomType.serifFallback,
                          color: _ink,
                        ),
                      ),
              onTap:
                  frame.supportsArt &&
                          _busy == null &&
                          _selected.containsKey(frame.id)
                      ? () => _toggle(frame)
                      : null,
            ),
          if (_selected.length <
                  widget.frames.where((f) => f.supportsArt).length &&
              _message != null)
            TextButton(
              style: _textButtonStyle,
              onPressed: _load,
              child: const Text('重试'),
            ),
        ],
      ),
    ),
  );
}

class _SendingDialog extends StatefulWidget {
  const _SendingDialog({
    required this.frame,
    required this.kind,
    required this.save,
    required this.reduceMotion,
  });
  final GalleryFrame frame;
  final String kind;
  final bool reduceMotion;
  final Future<Map<String, dynamic>> Function() save;
  @override
  State<_SendingDialog> createState() => _SendingDialogState();
}

class _SendingDialogState extends State<_SendingDialog> {
  Map<String, dynamic>? _result;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _send();
  }

  Future<void> _send() async {
    try {
      final values = await Future.wait<Object>([
        widget.save(),
        Future.delayed(
          Duration(milliseconds: widget.reduceMotion ? 0 : 1000),
          () => true,
        ),
      ]);
      if (!mounted) return;
      setState(() => _result = values.first as Map<String, dynamic>);
      unawaited(HapticFeedback.lightImpact());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _finish() {
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop(_result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_failed) ...[
          const Icon(
            Icons.cloud_off_outlined,
            color: BloomInk.textMuted,
            size: 40,
          ),
          const SizedBox(height: 18),
          const Text('暂时无法确认保存结果，请刷新状态后重试。', style: _prose),
        ] else ...[
          _SendingMoment(
            frame: widget.frame,
            sent: _result != null,
            kind: widget.kind,
          ),
          if (_result != null) ...[
            const SizedBox(height: 14),
            const Text('已发送，等待设备同步。', style: _prose),
          ],
        ],
        if (_result != null || _failed) ...[
          const SizedBox(height: 18),
          TextButton(
            style: _textButtonStyle,
            onPressed: _finish,
            child: Text(_failed ? '返回设备列表' : '完成'),
          ),
        ],
      ],
    );
    return PopScope(
      canPop: _result != null || _failed,
      child: Dialog(
        backgroundColor: BloomInk.panel,
        insetPadding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child:
              _result == null
                  ? content
                  : TweenAnimationBuilder<double>(
                    tween: Tween(begin: 1, end: 0),
                    duration: Duration(
                      milliseconds: widget.reduceMotion ? 800 : 1100,
                    ),
                    curve: const Interval(.7, 1, curve: Curves.easeOut),
                    onEnd: _finish,
                    builder:
                        (_, opacity, child) =>
                            Opacity(opacity: opacity, child: child),
                    child: content,
                  ),
        ),
      ),
    );
  }
}

class _SendingMoment extends StatelessWidget {
  const _SendingMoment({
    required this.frame,
    required this.sent,
    required this.kind,
  });
  final GalleryFrame frame;
  final bool sent;
  final String kind;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: sent ? '已发送，等待设备同步' : '正在发送到${frame.name}',
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: BloomInk.accentDeep,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BloomInk.controlEdge),
      ),
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            key: ValueKey(frame.id),
            tween: Tween(begin: 0, end: 1),
            duration: Duration(
              milliseconds: MediaQuery.of(context).disableAnimations ? 0 : 1000,
            ),
            curve: Curves.easeInOutCubic,
            builder:
                (context, t, _) => SizedBox(
                  height: 62,
                  child: LayoutBuilder(
                    builder:
                        (context, box) => Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned(
                              right: 12,
                              child: Icon(
                                frame.isMobile
                                    ? Icons.phone_iphone_rounded
                                    : Icons.tablet_mac_rounded,
                                size: 54,
                                color: BloomInk.accent,
                              ),
                            ),
                            Positioned(
                              left: 14,
                              child: Icon(
                                kind == 'collection'
                                    ? Icons.collections_outlined
                                    : Icons.photo_outlined,
                                color: _muted,
                                size: 30,
                              ),
                            ),
                            Positioned(
                              left: 18 + (box.maxWidth - 72) * t,
                              top: 20 - math.sin(t * math.pi) * 18,
                              child: Transform.rotate(
                                angle: (1 - t) * -.12,
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: BloomInk.text,
                                    borderRadius: BorderRadius.circular(4),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: .2,
                                        ),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    sent
                                        ? Icons.check_rounded
                                        : Icons.local_florist_outlined,
                                    size: 21,
                                    color: BloomInk.accentDeep,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                  ),
                ),
          ),
          const SizedBox(height: 10),
          Text(
            sent ? '让艺术，在日常里相遇。' : '正在送往「${frame.name}」',
            style: BloomType.rowTitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            sent
                ? '已保存，等待设备按原来的时间安排展示。'
                : '为${frame.isMobile ? '手机小组件' : '相框'}添一处风景',
            style: BloomType.meta,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class BloomContentManagerPage extends StatefulWidget {
  const BloomContentManagerPage({
    super.key,
    required this.api,
    required this.token,
    required this.frame,
  });
  final BloomApiClient api;
  final String token;
  final GalleryFrame frame;
  @override
  State<BloomContentManagerPage> createState() =>
      _BloomContentManagerPageState();
}

class _BloomContentManagerPageState extends State<BloomContentManagerPage> {
  List<Map<String, dynamic>>? _items;
  String? _error, _busy;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.contentSelections(
        widget.token,
        widget.frame.id,
      );
      if (mounted) {
        setState(() {
          _items = (data['items'] as List).cast<Map<String, dynamic>>();
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法读取展示内容。');
    }
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    if (!await _confirmRemoval(
      context,
      widget.frame.name,
      item['kind'] as String,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = item['id'] as String);
    try {
      await widget.api.changeContentSelection(
        widget.token,
        widget.frame.id,
        kind: item['kind'] as String,
        referenceId: item['id'] as String,
        selected: false,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _removalMessage(item['kind'] as String),
              style: _prose,
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('取消失败，请重试。', style: _prose)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(
      backgroundColor: _paper,
      foregroundColor: _ink,
      surfaceTintColor: Colors.transparent,
      title: const Text('展示内容', style: BloomType.rowTitle),
    ),
    body: BloomAtmosphere(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(widget.frame.name, style: _headline),
          const SizedBox(height: 16),
          const Text('在“发现”中发送展览或单幅作品。', style: _prose),
          const SizedBox(height: 24),
          if (_error != null) _Retry(message: _error!, onRetry: _load),
          if (_items == null && _error == null)
            const Center(child: CircularProgressIndicator()),
          if (_items != null && _items!.isEmpty)
            const Text('还没有发送艺术作品。', style: _prose),
          for (final item in _items ?? <Map<String, dynamic>>[])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                galleryArtworkText(
                      Map<String, dynamic>.from(item['metadata'] as Map? ?? {}),
                      'title',
                    ).isNotEmpty
                    ? galleryArtworkText(
                      Map<String, dynamic>.from(item['metadata'] as Map? ?? {}),
                      'title',
                    )
                    : '已下架的作品',
                style: BloomType.rowTitle,
              ),
              subtitle: Text(
                item['available'] == true
                    ? (item['kind'] == 'collection' ? '展览' : '单幅作品')
                    : '暂不可用',
                style: BloomType.meta,
              ),
              trailing: TextButton(
                style: _textButtonStyle,
                onPressed: _busy == null ? () => _remove(item) : null,
                child: Text(_busy == item['id'] ? '保存中' : '移除'),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(message, style: _prose),
      TextButton(
        style: _textButtonStyle,
        onPressed: onRetry,
        child: const Text('重试'),
      ),
    ],
  );
}
