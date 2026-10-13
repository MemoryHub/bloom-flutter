import 'package:flutter/material.dart';

/// Keeps the original composition; pinch to inspect details, double tap to zoom.
class BloomImageViewer extends StatefulWidget {
  const BloomImageViewer({super.key, required this.image, required this.title});
  final ImageProvider image;
  final String title;
  static Future<void> open(
    BuildContext context,
    ImageProvider image,
    String title,
  ) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => BloomImageViewer(image: image, title: title),
    ),
  );
  @override
  State<BloomImageViewer> createState() => _BloomImageViewerState();
}

class _BloomImageViewerState extends State<BloomImageViewer> {
  final _transform = TransformationController();
  Offset _tap = Offset.zero;
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: SafeArea(
      child: LayoutBuilder(
        builder:
            (context, box) => GestureDetector(
              onDoubleTapDown: (details) => _tap = details.localPosition,
              onDoubleTap: () {
                _transform.value =
                    _transform.value.getMaxScaleOnAxis() > 1.01
                        ? Matrix4.identity()
                        : (Matrix4.identity()
                          ..translate(-_tap.dx * 1.5, -_tap.dy * 1.5)
                          ..scale(2.5));
              },
              child: InteractiveViewer(
                key: const ValueKey('bloom-image-zoom'),
                transformationController: _transform,
                minScale: 1,
                maxScale: 8,
                child: SizedBox(
                  width: box.maxWidth,
                  height: box.maxHeight,
                  child: Image(
                    image: widget.image,
                    fit: BoxFit.contain,
                    loadingBuilder:
                        (context, child, loading) =>
                            loading == null
                                ? child
                                : const Center(
                                  child: CircularProgressIndicator(),
                                ),
                    errorBuilder:
                        (_, __, ___) => const Center(
                          child: Text(
                            '图片暂时无法加载，请返回重试。',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                  ),
                ),
              ),
            ),
      ),
    ),
  );
}
