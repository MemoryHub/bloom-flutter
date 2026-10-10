import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../core/api/bloom_api_client.dart';
import 'bloom_glass_home.dart';
import 'bloom_sign_in_prompt.dart';
import 'bloom_photo_detail_page.dart';
import 'bloom_photo_upload_page.dart';

String bloomPhotoDay(dynamic value) {
  final date = DateTime.tryParse('$value')?.toLocal();
  if (date == null) return '日期未知';
  return '${date.year}年${date.month}月${date.day}日';
}

class BloomPhotoLibraryPage extends StatefulWidget {
  const BloomPhotoLibraryPage({
    super.key,
    required this.api,
    this.token,
    this.ready = true,
    this.onSignIn,
    this.onChanged,
  });
  final BloomApiClient api;
  final String? token;
  final bool ready;
  final VoidCallback? onSignIn;
  final Future<void> Function()? onChanged;
  @override
  State<BloomPhotoLibraryPage> createState() => _BloomPhotoLibraryPageState();
}

// The date index is lightweight; photo metadata and bytes load only around the viewport.
class _PhotoRow {
  _PhotoRow(this.day, this.offset, this.count);
  final String day;
  final int offset, count; // count zero denotes a date heading.
  String get month => day.substring(0, 7);
}

class _BloomPhotoLibraryPageState extends State<BloomPhotoLibraryPage> {
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _rail = ScrollController();
  final _pages = <int, List<Map<String, dynamic>>>{};
  final _pending = <int>{}, _fetching = <int>{}, _failed = <int>{};
  final List<_PhotoRow> _rows = [];
  final Map<String, int> _months = {};
  String? _month, _error;
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_visibleChanged);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant BloomPhotoLibraryPage old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token || old.ready != widget.ready) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _generation++;
    _positions.itemPositions.removeListener(_visibleChanged);
    _rail.dispose();
    super.dispose();
  }

  void _visibleChanged() {
    final visible = _positions.itemPositions.value.where(
      (p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1,
    );
    if (visible.isEmpty || _rows.isEmpty) return;
    final first = visible.reduce((a, b) => a.index < b.index ? a : b);
    if (first.index >= _rows.length) return;
    final month = _rows[first.index].month;
    if (month == _month) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_months.containsKey(month)) return;
      setState(() => _month = month);
      final index = _months.keys.toList().indexOf(month);
      if (_rail.hasClients) {
        final target = (index * 56.0 -
                _rail.position.viewportDimension / 2 +
                28)
            .clamp(0.0, _rail.position.maxScrollExtent);
        unawaited(
          _rail.animateTo(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() {
      _rows.clear();
      _months.clear();
      _pages.clear();
      _pending.clear();
      _fetching.clear();
      _failed.clear();
      _month = null;
      _error = null;
      _loading = widget.token != null && widget.ready;
    });
    final token = widget.token;
    if (token == null || !widget.ready) return;
    try {
      final result = await widget.api.userRequest(token, 'photos/days');
      if (!mounted || generation != _generation) return;
      var offset = 0;
      for (final entry in result['days'] as List) {
        final day = entry['day'] as String;
        final count = (entry['count'] as num).toInt();
        _months.putIfAbsent(day.substring(0, 7), () => _rows.length);
        _rows.add(_PhotoRow(day, offset, 0));
        for (var i = 0; i < count; i += 3) {
          _rows.add(_PhotoRow(day, offset + i, (count - i).clamp(0, 3)));
        }
        offset += count;
      }
      setState(() {
        _loading = false;
        _month = _months.keys.firstOrNull;
      });
      if (_rows.isNotEmpty) _requestPage(0);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = '暂时无法读取照片，请重试。';
        });
      }
    }
  }

  void _requestPage(int page) {
    if (_pages.containsKey(page) ||
        _fetching.contains(page) ||
        _failed.contains(page) ||
        widget.token == null) {
      return;
    }
    _pending.add(page);
    // Builders only enqueue; mutate widgets after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _drain();
    });
  }

  void _drain() {
    while (_fetching.length < 2 && _pending.isNotEmpty) {
      final page = _pending.first;
      _pending.remove(page);
      if (_pages.containsKey(page) || _fetching.contains(page)) continue;
      _fetching.add(page);
      unawaited(_loadPage(page));
    }
  }

  Future<void> _loadPage(int page) async {
    final generation = _generation, token = widget.token!;
    try {
      final result = await widget.api.userRequest(
        token,
        'photos',
        query: {'offset': '${page * 60}', 'limit': '60'},
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _pages[page] =
            (result['photos'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
        while (_pages.length > 8) {
          _pages.remove(_pages.keys.first);
        }
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _failed.add(page));
      }
    } finally {
      if (mounted && generation == _generation) {
        _fetching.remove(page);
        _drain();
      }
    }
  }

  Future<void> _open(Map<String, dynamic> photo) async {
    final token = widget.token;
    if (token == null) return;
    // Refresh on return also handles iOS interactive back, which returns no route result.
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder:
            (_) => BloomPhotoDetailPage(
              api: widget.api,
              token: token,
              photo: photo,
            ),
      ),
    );
    if (!mounted || token != widget.token) return;
    if (result?['deleted'] == true) {
      await widget.onChanged?.call();
      await _refresh();
    } else {
      try {
        final detail = await widget.api.userRequest(
          token,
          'photos/${photo['id']}',
        );
        if (!mounted || token != widget.token) return;
        setState(
          () =>
              photo['scores'] =
                  detail['photo']['analysis']?['scores'] ?? photo['scores'],
        );
      } catch (_) {
        /* Keep the successful thumbnail when offline. */
      }
      await widget.onChanged?.call();
    }
  }

  Future<void> _upload() async {
    final token = widget.token;
    if (token == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => BloomPhotoUploadPage(api: widget.api, token: token),
      ),
    );
    if (mounted && token == widget.token) {
      await _refresh();
      await widget.onChanged?.call();
    }
  }

  void _jump(String month) {
    if (!_scroll.isAttached || !_months.containsKey(month)) return;
    // This is a jump within one continuous timeline, not a month filter.
    _scroll.jumpTo(index: _months[month]!);
  }

  Widget _row(BuildContext context, int index) {
    final row = _rows[index];
    if (row.count == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 10),
        child: Text(bloomPhotoDay(row.day), style: BloomType.labelStrong),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = (constraints.maxWidth - 8) / 3;
          return SizedBox(
            height: height,
            child: Row(
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child:
                        i >= row.count
                            ? const SizedBox.shrink()
                            : _at(row.offset + i),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _at(int offset) {
    final page = offset ~/ 60, inPage = offset % 60;
    final photos = _pages[page];
    if (photos != null && inPage < photos.length) {
      final photo = photos[inPage];
      return _PhotoTile(
        key: ValueKey('photo-$_generation-${photo['id']}'),
        api: widget.api,
        token: widget.token!,
        photo: photo,
        onTap: () => _open(photo),
      );
    }
    _requestPage(page);
    return ColoredBox(
      color: BloomInk.panel,
      child: Center(
        child:
            _failed.contains(page)
                ? IconButton(
                  tooltip: '重新加载',
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: BloomInk.textFaint,
                  ),
                  onPressed: () {
                    setState(() => _failed.remove(page));
                    _requestPage(page);
                  },
                )
                : const Icon(Icons.photo_outlined, color: BloomInk.textFaint),
      ),
    );
  }

  Widget _timeline() => SizedBox(
    width: 44,
    child: ListView.builder(
      controller: _rail,
      itemExtent: 56,
      padding: const EdgeInsets.only(bottom: 112),
      itemCount: _months.length,
      itemBuilder: (context, index) {
        final month = _months.keys.elementAt(index), selected = month == _month;
        return InkWell(
          onTap: () => _jump(month),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: selected ? BloomInk.panel : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border(
                left: BorderSide(
                  color: selected ? BloomInk.accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              month.replaceFirst('-', '\n'),
              textAlign: TextAlign.center,
              style: BloomType.meta.copyWith(
                fontSize: 11,
                color: selected ? BloomInk.text : BloomInk.textFaint,
              ),
            ),
          ),
        );
      },
    ),
  );

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
        Row(
          children: [
            const Expanded(child: BloomPageTitle(title: '照片')),
            if (widget.token != null)
              IconButton(
                tooltip: '上传照片',
                onPressed: widget.ready ? _upload : null,
                icon: const Icon(
                  Icons.add_photo_alternate_outlined,
                  color: BloomInk.text,
                ),
              ),
          ],
        ),
        const SizedBox(height: BloomPageTitle.contentGap),
        Expanded(
          child:
              widget.token == null
                  ? Padding(
                    padding: const EdgeInsets.only(bottom: 96),
                    child: BloomSignInPrompt(
                      key: const ValueKey('bloom-photos-signed-out'),
                      illustration: const BloomEmptyFrameIllustration(),
                      title: '登录后查看你的照片',
                      message: '在这里回看照片，把回忆带到你的设备上。',
                      onSignIn: widget.onSignIn,
                    ),
                  )
                  : !widget.ready
                  ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        BloomEmptyFrameIllustration(),
                        SizedBox(height: 22),
                        Text('正在准备你的图库', style: BloomType.rowTitle),
                        SizedBox(height: 10),
                        Text('准备完成后会自动显示照片。', style: BloomType.body),
                      ],
                    ),
                  )
                  : _loading
                  ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: BloomInk.accent,
                    ),
                  )
                  : _error != null
                  ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, style: BloomType.body),
                        TextButton(
                          onPressed: _refresh,
                          child: const Text('重试', style: BloomType.button),
                        ),
                      ],
                    ),
                  )
                  : _rows.isEmpty
                  ? RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 90),
                        BloomEmptyFrameIllustration(),
                        SizedBox(height: 22),
                        Center(
                          child: Text('这里还没有照片', style: BloomType.rowTitle),
                        ),
                      ],
                    ),
                  )
                  : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _refresh,
                          color: BloomInk.accent,
                          child: ScrollablePositionedList.builder(
                            key: ValueKey('library-$_generation'),
                            itemCount: _rows.length,
                            itemScrollController: _scroll,
                            itemPositionsListener: _positions,
                            padding: const EdgeInsets.only(bottom: 112),
                            physics: const AlwaysScrollableScrollPhysics(
                              parent: BouncingScrollPhysics(),
                            ),
                            itemBuilder: _row,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _timeline(),
                    ],
                  ),
        ),
      ],
    ),
  );
}

class _PhotoTile extends StatefulWidget {
  const _PhotoTile({
    super.key,
    required this.api,
    required this.token,
    required this.photo,
    required this.onTap,
  });
  final BloomApiClient api;
  final String token;
  final Map<String, dynamic> photo;
  final VoidCallback onTap;
  @override
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> {
  late Future<Uint8List> _image;
  @override
  void initState() {
    super.initState();
    _image = widget.api.photoThumbnail(
      widget.token,
      widget.photo['id'] as String,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scores = widget.photo['scores'] as Map? ?? {};
    return Semantics(
      label: '${bloomPhotoDay(widget.photo['taken_at'])}的照片',
      button: true,
      child: InkWell(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(BloomSurface.innerRadius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: BloomInk.panel,
                child: FutureBuilder<Uint8List>(
                  future: _image,
                  builder:
                      (context, snapshot) =>
                          snapshot.hasData
                              ? Image.memory(
                                snapshot.data!,
                                fit: BoxFit.cover,
                                cacheWidth: 384,
                              )
                              : const Icon(
                                Icons.photo_outlined,
                                color: BloomInk.textFaint,
                              ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 5),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (final pair in [
                        ('感染', 'moment'),
                        ('回味', 'reflection'),
                        ('展示', 'display'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(left: 5),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                pair.$1,
                                style: BloomType.meta.copyWith(
                                  fontSize: 8,
                                  color: Colors.white70,
                                ),
                              ),
                              Text(
                                scores[pair.$2] == null
                                    ? '—'
                                    : (scores[pair.$2] as num).toStringAsFixed(
                                      0,
                                    ),
                                style: BloomType.meta.copyWith(
                                  fontSize: 11,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
