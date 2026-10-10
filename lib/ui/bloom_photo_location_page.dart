import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../core/api/bloom_api_client.dart';
import 'bloom_glass_home.dart';

class BloomPhotoLocationPage extends StatefulWidget {
  const BloomPhotoLocationPage({
    super.key,
    required this.api,
    required this.token,
    required this.assetId,
    this.latitude,
    this.longitude,
    this.locationText,
  });
  final BloomApiClient api;
  final String token, assetId;
  final double? latitude, longitude;
  final String? locationText;
  @override
  State<BloomPhotoLocationPage> createState() => _BloomPhotoLocationPageState();
}

class _BloomPhotoLocationPageState extends State<BloomPhotoLocationPage> {
  final _query = TextEditingController(),
      _latitude = TextEditingController(),
      _longitude = TextEditingController();
  final _map = MapController();
  List<Map<String, dynamic>> _places = [];
  LatLng? _selected;
  bool _searching = false, _saving = false;
  bool _resolving = false;
  int _locationRevision = 0;
  Timer? _resolveTimer;
  String? _selectedName;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (widget.latitude != null && widget.longitude != null) {
      _select(
        LatLng(widget.latitude!, widget.longitude!),
        move: false,
        resolve: false,
      );
      _selectedName = widget.locationText;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _latitude.dispose();
    _longitude.dispose();
    _map.dispose();
    _resolveTimer?.cancel();
    super.dispose();
  }

  void _select(LatLng point, {bool move = true, bool resolve = true}) {
    _selected = point;
    _latitude.text = point.latitude.toStringAsFixed(6);
    _longitude.text = point.longitude.toStringAsFixed(6);
    if (move) _map.move(point, 13);
    if (resolve) _scheduleResolve(point);
  }

  void _scheduleResolve(LatLng point) {
    _resolveTimer?.cancel();
    final revision = ++_locationRevision;
    _selectedName = null;
    _resolving = true;
    _resolveTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        final result = await widget.api.userRequest(
          widget.token,
          'photo-locations/resolve',
          query: {
            'latitude': '${point.latitude}',
            'longitude': '${point.longitude}',
          },
        );
        if (!mounted || revision != _locationRevision) return;
        setState(() {
          _selectedName = result['location_text'] as String?;
          _resolving = false;
        });
      } catch (_) {
        if (!mounted || revision != _locationRevision) return;
        setState(() {
          _resolving = false;
          _error = '地点名称暂时无法获取，请重试搜索或选择附近城市。';
        });
      }
    });
  }

  void _coordinatesChanged(String _) {
    final lat = double.tryParse(_latitude.text),
        lon = double.tryParse(_longitude.text);
    setState(() {
      _resolveTimer?.cancel();
      ++_locationRevision;
      _selectedName = null;
      _resolving = false;
      if (lat != null &&
          lon != null &&
          lat.isFinite &&
          lon.isFinite &&
          lat.abs() <= 90 &&
          lon.abs() <= 180) {
        _selected = LatLng(lat, lon);
        _scheduleResolve(_selected!);
      }
    });
  }

  Future<void> _search() async {
    if (_searching || _query.text.trim().length < 2) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final result = await widget.api.userRequest(
        widget.token,
        'photo-locations',
        query: {'query': _query.text.trim()},
      );
      if (!mounted) return;
      setState(() {
        _places =
            (result['places'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
        if (_places.isEmpty) _error = '没有找到这个地点，可直接在地图上选择或填写经纬度。';
      });
    } catch (_) {
      if (mounted) setState(() => _error = '地点搜索暂时不可用，可在地图上选择或填写经纬度。');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final latitude = double.tryParse(_latitude.text),
        longitude = double.tryParse(_longitude.text);
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      setState(() => _error = '请先选择地点，或填写有效的经纬度。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.api.userRequest(
        widget.token,
        'photos/${widget.assetId}/location',
        method: 'PATCH',
        body: {'latitude': latitude, 'longitude': longitude},
      );
      if (mounted) Navigator.pop(context, result['photo']);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is BloomApiException &&
                          error.code == 'location_name_unavailable'
                      ? '这个位置还无法识别地名，请搜索或选择附近的城市后保存。'
                      : '位置没有保存成功，请检查网络后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _input(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: BloomType.meta,
    filled: true,
    fillColor: BloomInk.recess,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(BloomSurface.innerRadius),
      borderSide: const BorderSide(color: BloomInk.divider),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BloomInk.page,
    appBar: AppBar(
      backgroundColor: BloomInk.page,
      foregroundColor: BloomInk.text,
      title: const Text('照片位置', style: BloomType.pageTitle),
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(BloomSurface.pageInset),
        children: [
          const Text('这份回忆发生在哪里', style: BloomType.sectionTitle),
          const SizedBox(height: 10),
          Text(
            _resolving
                ? '正在识别地点…'
                : (_selectedName?.isNotEmpty == true
                    ? _selectedName!
                    : '请选择地点'),
            style: BloomType.labelStrong,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  style: BloomType.body,
                  decoration: _input('搜索城市或地点'),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                ),
              ),
              IconButton(
                tooltip: '搜索地点',
                onPressed: _searching ? null : _search,
                icon: Icon(
                  _searching ? Icons.hourglass_empty : Icons.search,
                  color: BloomInk.text,
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: BloomType.meta),
            ),
          for (final place in _places)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${place['name']}', style: BloomType.labelStrong),
              subtitle: Text(
                [
                  place['admin1name'],
                  place['admin2name'],
                ].where((e) => e != null).join(' · '),
                style: BloomType.meta,
              ),
              onTap:
                  () => setState(() {
                    _select(
                      LatLng(
                        (place['latitude'] as num).toDouble(),
                        (place['longitude'] as num).toDouble(),
                      ),
                    );
                    _places = [];
                  }),
            ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(BloomSurface.radius),
            child: SizedBox(
              height: 300,
              child: FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCenter: _selected ?? const LatLng(39.9042, 116.4074),
                  initialZoom: _selected == null ? 4 : 12,
                  onTap:
                      (_, point) => setState(() => _select(point, move: false)),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.bloom.bloom',
                  ),
                  if (_selected != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _selected!,
                          width: 40,
                          height: 40,
                          child: const Icon(
                            Icons.location_on,
                            size: 36,
                            color: BloomInk.accent,
                          ),
                        ),
                      ],
                    ),
                  const SimpleAttributionWidget(
                    source: Text(
                      '© OpenStreetMap contributors',
                      style: TextStyle(fontSize: 10, color: Colors.black87),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text('搜索地点或轻点地图，保存后会显示地点名称。', style: BloomType.meta),
          const SizedBox(height: 16),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('精确调整位置', style: BloomType.meta),
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _latitude,
                      onChanged: _coordinatesChanged,
                      style: BloomType.body,
                      decoration: _input('纬度'),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _longitude,
                      onChanged: _coordinatesChanged,
                      style: BloomType.body,
                      decoration: _input('经度'),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 22),
          BloomPrimaryButton(
            label: _saving ? '正在保存…' : '保存位置',
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    ),
  );
}
