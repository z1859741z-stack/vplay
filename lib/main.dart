import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:volume_controller/volume_controller.dart';

/// 外观模式：dark / light / system，存在本地
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 性能拉满：图片缓存不设小气上限，滚动不重复解码、不闪白
  PaintingBinding.instance.imageCache.maximumSize = 1000;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 500 * 1024 * 1024;
  final prefs = await SharedPreferences.getInstance();
  final t = prefs.getString('theme_mode') ?? 'dark';
  themeMode.value =
      t == 'light' ? ThemeMode.light : t == 'system' ? ThemeMode.system : ThemeMode.dark;
  await LiquidGlassWidgets.initialize(); // 预热液态玻璃 shader
  runApp(const VPlayApp());
}

class VPlayApp extends StatelessWidget {
  const VPlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: '影搜',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: ThemeData.light().copyWith(
            scaffoldBackgroundColor: const Color(0xFFF5F5F5),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF5F5F5),
              foregroundColor: Colors.black,
              elevation: 0,
            ),
            colorScheme: const ColorScheme.light(
              primary: kYellow,
              secondary: kYellow,
              secondaryContainer: Color(0xFFFFF0B3),
              onSecondaryContainer: Color(0xFF7A5C00),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(foregroundColor: Colors.black),
            ),
          ),
          darkTheme: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: kBg,
            appBarTheme: const AppBarTheme(
              backgroundColor: kBg,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            colorScheme: const ColorScheme.dark(
              primary: kYellow,
              secondary: kYellow,
              secondaryContainer: Color(0xFF3D3200),
              onSecondaryContainer: kYellow,
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(foregroundColor: Colors.black),
            ),
          ),
          home: const MainNav(),
        );
      },
    );
  }
}

// ---------- 液态玻璃风 ----------

const kYellow = Color(0xFFFFC107);
const kBg = Color(0xFF0B0B0B);

/// 磨砂玻璃容器
Widget glassBox({required Widget child, double radius = 24, double opacity = 0.18, Color tint = Colors.white}) {
  // 真液态玻璃：shader 折射 + 色散 + 高光，不是普通模糊盒子
  final alpha = (opacity * 255).round().clamp(20, 140);
  return AdaptiveGlass(
    shape: LiquidRoundedRectangle(borderRadius: radius),
    quality: GlassQuality.premium,
    settings: LiquidGlassSettings(
      thickness: 20,
      blur: 3,
      refractiveIndex: 1.3,
      chromaticAberration: 0.012,
      saturation: 1.4,
      lightIntensity: 0.75,
      glassColor: Color.fromARGB(alpha, tint.red, tint.green, tint.blue),
    ),
    child: child,
  );
}

/// 海报网格宽高比：按屏宽算，海报 16:10 + 两行字，避免格子过高留黑空
double posterGridAspect(BuildContext context) {
  final w = (MediaQuery.of(context).size.width - 44) / 2;
  return w / (w * 10 / 16 + 50);
}

/// 分区标题：黄色竖条 + 标题 + 更多
Widget sectionHeader(String title, {VoidCallback? onMore}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
    child: Row(
      children: [
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            color: kYellow,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        const Spacer(),
        if (onMore != null)
          GestureDetector(
            onTap: onMore,
            child: const Row(
              children: [
                Text('更多', style: TextStyle(color: Colors.grey, fontSize: 14)),
                Icon(Icons.chevron_right, color: Colors.grey, size: 18),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 画质角标（从备注里找 4K/蓝光等，有才显示）
String badgeOf(Vod v) {
  final s = '${v.name} ${v.remarks}';
  if (s.contains('4K') || s.contains('2160')) return '4K';
  if (s.contains('蓝光')) return '蓝光';
  if (s.contains('1080')) return '1080P';
  if (s.contains('杜比')) return '杜比';
  if (s.contains('原画')) return '原画';
  if (s.contains('超清')) return '超清';
  if (s.contains('高清')) return '高清';
  if (s.contains('HD')) return 'HD';
  return '';
}

/// 统一的海报卡片：16:10 海报 + 标题 + 副标题，点开进详情
class VodCard extends StatelessWidget {
  final Vod vod;
  final double titleSize;
  final bool onlyMandarin;
  const VodCard({super.key, required this.vod, this.titleSize = 14, this.onlyMandarin = true});

  @override
  Widget build(BuildContext context) {
    final badge = badgeOf(vod);
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DetailPage(vod: vod, onlyMandarin: onlyMandarin)),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: vod.pic.isEmpty
                      ? Container(
                          color: const Color(0xFF242424),
                          child: const Center(child: Icon(Icons.movie, size: 36, color: Colors.grey)),
                        )
                      : CachedNetworkImage(
                          imageUrl: vod.pic,
                          memCacheWidth: 800,
                          memCacheHeight: 500,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                          errorWidget: (_, __, ___) => Container(
                            color: const Color(0xFF242424),
                            child: const Center(child: Icon(Icons.broken_image, color: Colors.grey)),
                          ),
                        ),
                ),
                if (badge.isNotEmpty)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: kYellow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        badge,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            vod.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            [vod.year, vod.remarks].where((e) => e.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

// ---------- 片源 ----------

const List<Map<String, String>> kSources = [
  {'name': '光速', 'url': 'https://api.guangsuapi.com/api.php/provide/vod/'},
  {'name': '红牛', 'url': 'https://www.hongniuzy2.com/api.php/provide/vod/'},
  {'name': '360', 'url': 'https://360zy.com/api.php/provide/vod/'},
  {'name': '魔都', 'url': 'https://www.mdzyapi.com/api.php/provide/vod/'},
  {'name': '百度云', 'url': 'https://api.apibdzy.com/api.php/provide/vod/'},
  {'name': '暴风', 'url': 'https://bfzyapi.com/api.php/provide/vod/'},
  {'name': '无尽', 'url': 'https://api.wujinapi.me/api.php/provide/vod/'},
];

const List<String> kMandarinMarkers = ['国语', '国配', '中文配音', '普通话', '中配', '国语版'];

// ---------- 源列表：远程自动更新 ----------

/// 远程源列表：App 启动时自动拉取，改这个文件不用重新编译。
const kRemoteSourcesUrl =
    'https://raw.githubusercontent.com/z1859741z-stack/vplay/main/sources.json';

List<Map<String, String>> _parseSourceList(dynamic decoded) {
  if (decoded is! List) return [];
  return decoded
      .whereType<Map>()
      .map((e) => {'name': '${e['name'] ?? ''}', 'url': '${e['url'] ?? ''}'})
      .where((m) => m['name']!.isNotEmpty && m['url']!.startsWith('http'))
      .toList();
}

/// 拉远程源列表（成功则缓存并返回，失败返回 null）
Future<List<Map<String, String>>?> fetchRemoteSources() async {
  try {
    final resp = await http.get(Uri.parse(kRemoteSourcesUrl)).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final list = _parseSourceList(jsonDecode(resp.body));
    if (list.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('remote_sources_json', jsonEncode(list));
    await prefs.setInt('remote_sources_updated_at', DateTime.now().millisecondsSinceEpoch);
    return list;
  } catch (_) {
    return null;
  }
}

/// 基础源 = 上次拉到的远程列表，没有则用内置
Future<List<Map<String, String>>> readBaseSources() async {
  final prefs = await SharedPreferences.getInstance();
  final cached = prefs.getString('remote_sources_json');
  if (cached != null) {
    try {
      final list = _parseSourceList(jsonDecode(cached));
      if (list.isNotEmpty) return list;
    } catch (_) {}
  }
  return kSources;
}

Future<List<Map<String, String>>> readCustomSources() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('custom_sources_json');
  if (raw == null) return [];
  try {
    return _parseSourceList(jsonDecode(raw));
  } catch (_) {
    return [];
  }
}

Future<List<String>> readDisabledUrls() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList('disabled_source_urls') ?? [];
}

/// 生效的源 = 基础源 + 自加源，去掉被关掉的
Future<List<Map<String, String>>> effectiveSources() async {
  final base = await readBaseSources();
  final custom = await readCustomSources();
  final disabled = await readDisabledUrls();
  final all = [...base, ...custom];
  return all.where((s) => !disabled.contains(s['url'])).toList();
}

// ---------- 数据模型 ----------

class Vod {
  final String id;
  final String name;
  final String pic;
  final String year;
  final String area;
  final String remarks;
  final String vodClass;
  final String typeName;
  final String source;
  final String sourceUrl;

  Vod({
    required this.id,
    required this.name,
    required this.pic,
    required this.year,
    required this.area,
    required this.remarks,
    required this.vodClass,
    required this.typeName,
    required this.source,
    required this.sourceUrl,
  });

  factory Vod.fromJson(Map<String, dynamic> j, String source, String sourceUrl) {
    return Vod(
      id: '${j['vod_id'] ?? ''}',
      name: '${j['vod_name'] ?? ''}',
      pic: '${j['vod_pic'] ?? ''}',
      year: '${j['vod_year'] ?? ''}',
      area: '${j['vod_area'] ?? ''}',
      remarks: '${j['vod_remarks'] ?? ''}',
      vodClass: '${j['vod_class'] ?? ''}',
      typeName: '${j['type_name'] ?? ''}',
      source: source,
      sourceUrl: sourceUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'pic': pic,
        'year': year,
        'area': area,
        'remarks': remarks,
        'vodClass': vodClass,
        'typeName': typeName,
        'source': source,
        'sourceUrl': sourceUrl,
      };

  factory Vod.fromFav(Map<String, dynamic> j) => Vod(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        pic: '${j['pic'] ?? ''}',
        year: '${j['year'] ?? ''}',
        area: '${j['area'] ?? ''}',
        remarks: '${j['remarks'] ?? ''}',
        vodClass: '${j['vodClass'] ?? ''}',
        typeName: '${j['typeName'] ?? ''}',
        source: '${j['source'] ?? ''}',
        sourceUrl: '${j['sourceUrl'] ?? ''}',
      );
}

class Episode {
  final String name;
  final String url;
  Episode(this.name, this.url);
}

class PlayLine {
  final String name;
  final List<Episode> episodes;
  PlayLine(this.name, this.episodes);
}

// ---------- CMS 接口 ----------

Future<List<Vod>> searchSource(String base, String sourceName, String keyword) async {
  final uri = Uri.parse('$base?ac=videolist&wd=${Uri.encodeQueryComponent(keyword)}&pg=1');
  final resp = await http.get(uri).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) return [];
  final data = jsonDecode(resp.body);
  final list = (data['list'] as List?) ?? [];
  return list
      .map((e) => Vod.fromJson(e as Map<String, dynamic>, sourceName, base))
      .where((v) => v.name.isNotEmpty)
      .toList();
}

Future<List<Vod>> searchAll(String keyword,
    {String? onlySource, required List<Map<String, String>> sources}) async {
  final targets = onlySource == null
      ? sources
      : sources.where((s) => s['name'] == onlySource).toList();
  final results = await Future.wait(
    targets.map((s) => searchSource(s['url']!, s['name']!, keyword).catchError((_) => <Vod>[])),
  );
  final all = results.expand((e) => e).toList();
  final seen = <String>{};
  return all.where((v) {
    final key = '${v.name}|${v.year}';
    if (seen.contains(key)) return false;
    seen.add(key);
    return true;
  }).toList();
}

/// 拉某个源的最新列表（不带关键词就是最新）
Future<List<Vod>> fetchLatest(String base, String sourceName, {int pg = 1}) async {
  final uri = Uri.parse('$base?ac=videolist&pg=$pg');
  final resp = await http.get(uri).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) return [];
  final data = jsonDecode(resp.body);
  final list = (data['list'] as List?) ?? [];
  return list
      .map((e) => Vod.fromJson(e as Map<String, dynamic>, sourceName, base))
      .where((v) => v.name.isNotEmpty)
      .toList();
}

// ---------- 收藏 ----------

Future<List<Vod>> readFavorites() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('favorites_json');
  if (raw == null) return [];
  try {
    final list = jsonDecode(raw) as List;
    return list.map((e) => Vod.fromFav(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
}

Future<bool> isFavorite(Vod v) async {
  final list = await readFavorites();
  return list.any((e) => e.id == v.id && e.sourceUrl == v.sourceUrl);
}

/// 收藏/取消收藏，返回收藏后的状态
Future<bool> toggleFavorite(Vod v) async {
  final prefs = await SharedPreferences.getInstance();
  final list = await readFavorites();
  final i = list.indexWhere((e) => e.id == v.id && e.sourceUrl == v.sourceUrl);
  final nowFav;
  if (i >= 0) {
    list.removeAt(i);
    nowFav = false;
  } else {
    list.add(v);
    nowFav = true;
  }
  await prefs.setString('favorites_json', jsonEncode(list.map((e) => e.toJson()).toList()));
  return nowFav;
}

Future<({List<PlayLine> lines, String blurb})> fetchLines(String base, String vodId) async {
  final uri = Uri.parse('$base?ac=detail&ids=$vodId');
  final resp = await http.get(uri).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) return (lines: <PlayLine>[], blurb: '');
  final data = jsonDecode(resp.body);
  final list = (data['list'] as List?) ?? [];
  if (list.isEmpty) return (lines: <PlayLine>[], blurb: '');
  final item = list[0] as Map<String, dynamic>;
  final playUrl = '${item['vod_play_url'] ?? ''}';
  final blurb = '${item['vod_blurb'] ?? ''}'.trim();
  return (lines: parsePlayUrl(playUrl), blurb: blurb);
}

// vod_play_url 格式：线路名$第01集$url#第02集$url$$$线路2$...
/// 集名特征：含 集/话、叫正片、或纯数字编号 —— 这类“名字”不是线路名
bool _isEpisodeName(String s) {
  if (s.isEmpty) return true;
  if (s == '正片') return true;
  if (s.contains('集') || s.contains('话')) return true;
  if (RegExp(r'^第?\d+$').hasMatch(s)) return true;
  if (RegExp(r'^\d+[._\-]').hasMatch(s)) return true;
  return false;
}

List<PlayLine> parsePlayUrl(String playUrl) {
  final lines = <PlayLine>[];
  var lineNo = 0;
  for (final part in playUrl.split('\$\$\$')) {
    if (part.trim().isEmpty) continue;
    final dollar = part.indexOf('\$');
    if (dollar < 0) {
      // 整段就是一个裸地址（单集直链）
      final url = part.trim();
      if (url.startsWith('http')) {
        lineNo++;
        lines.add(PlayLine('线路$lineNo', [Episode('正片', url)]));
      }
      continue;
    }
    var lineName = part.substring(0, dollar).trim();
    var rest = part.substring(dollar + 1);
    // 有的源不写线路名，直接以“第1集$地址#第2集$地址”开头：
    // 第一段其实是集名，不是线路名，别把它吞掉
    if (_isEpisodeName(lineName)) {
      lineNo++;
      lineName = '线路$lineNo';
      rest = part;
    }
    final eps = <Episode>[];
    for (final ep in rest.split('#')) {
      if (ep.trim().isEmpty) continue;
      final i = ep.indexOf('\$');
      if (i < 0) {
        // 单集直链：没有集数名，整段就是播放地址（电影常见）
        final url = ep.trim();
        if (url.startsWith('http')) eps.add(Episode('正片', url));
        continue;
      }
      final name = ep.substring(0, i).trim();
      final url = ep.substring(i + 1).trim();
      if (url.isEmpty) continue;
      if (_isBad(name)) continue;
      eps.add(Episode(name, url));
    }
    if (eps.isNotEmpty) lines.add(PlayLine(lineName, eps));
  }
  return lines;
}

bool _isBad(String name) {
  return name.contains('枪版') ||
      name.contains('TC') ||
      name.contains('抢先') ||
      name.contains('预告') ||
      name.contains('花絮');
}

bool _isMandarin(String s) {
  for (final m in kMandarinMarkers) {
    if (s.contains(m)) return true;
  }
  return false;
}

/// 只看国语开着时，只留国语线；没有国语线则回退到全部，避免结果为空。
List<PlayLine> filterMandarin(List<PlayLine> lines, bool onlyMandarin) {
  if (!onlyMandarin) return lines;
  final kept = lines.map((l) {
    final eps = l.episodes.where((e) => _isMandarin(e.name) || _isMandarin(l.name)).toList();
    return PlayLine(l.name, eps);
  }).where((l) => l.episodes.isNotEmpty).toList();
  return kept.isEmpty ? lines : kept;
}

String qualityOf(String name) {
  if (name.contains('4K')) return '4K';
  if (name.contains('1080')) return '1080p';
  if (name.contains('720')) return '720p';
  if (name.contains('蓝光')) return '蓝光';
  if (name.contains('超清')) return '超清';
  if (name.contains('高清')) return '高清';
  return '';
}

// ---------- 搜索页 ----------

class SearchPage extends StatefulWidget {
  final String? initialKeyword;
  const SearchPage({super.key, this.initialKeyword});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _keywordCtl = TextEditingController();
  final _linkCtl = TextEditingController();
  String? _onlySource;
  bool _onlyMandarin = true;
  String _type = '全部';
  static const _types = ['全部', '电影', '电视剧', '动漫', '综艺'];

  /// 按类型过滤后的结果（类型从片名/分类/备注里匹配）
  List<Vod> get _shown {
    if (_type == '全部') return _results;
    final keys = _type == '动漫' ? ['动漫', '动画', '国漫', '日漫'] : [_type];
    return _results.where((v) {
      final s = '${v.typeName} ${v.vodClass} ${v.name}';
      return keys.any(s.contains);
    }).toList();
  }
  List<Vod> _results = [];
  List<String> _history = [];
  List<Map<String, String>> _sources = kSources;
  bool _searching = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadSources();
    if ((widget.initialKeyword ?? '').isNotEmpty) {
      _keywordCtl.text = widget.initialKeyword!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _doSearch(widget.initialKeyword));
    }
  }

  /// 启动时拉一次远程源列表，失败就用上次缓存的或内置的
  Future<void> _loadSources() async {
    await fetchRemoteSources();
    final list = await effectiveSources();
    if (!mounted) return;
    setState(() {
      _sources = list;
      if (_onlySource != null && !_sources.any((s) => s['name'] == _onlySource)) {
        _onlySource = null;
      }
    });
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _history = prefs.getStringList('search_history') ?? [];
    });
  }

  Future<void> _saveHistory(String kw) async {
    final prefs = await SharedPreferences.getInstance();
    final list = [kw, ..._history.where((e) => e != kw)].take(10).toList();
    await prefs.setStringList('search_history', list);
    setState(() => _history = list);
  }

  Future<void> _doSearch([String? kw]) async {
    final keyword = (kw ?? _keywordCtl.text).trim();
    if (keyword.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _status = '正在搜…';
      _results = [];
    });
    await _saveHistory(keyword);
    final results = await searchAll(keyword, onlySource: _onlySource, sources: _sources);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = results;
      _status = results.isEmpty ? '没搜到，换个词或换个源试试' : '搜到 ${results.length} 条';
    });
  }

  void _playLink() {
    final url = _linkCtl.text.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('链接要以 http 开头')));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(title: '直接播放', directUrl: url),
      ),
    );
  }

  void _pickSource() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择片源', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              title: const Text('全部源'),
              trailing: _onlySource == null ? const Icon(Icons.check, color: kYellow) : null,
              onTap: () {
                Navigator.pop(context);
                setState(() => _onlySource = null);
              },
            ),
            for (final s in _sources)
              ListTile(
                title: Text(s['name']!),
                trailing:
                    _onlySource == s['name'] ? const Icon(Icons.check, color: kYellow) : null,
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _onlySource = s['name']);
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showLinkDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('粘贴链接直接播'),
        content: TextField(
          controller: _linkCtl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'm3u8 / mp4 链接'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _playLink();
            },
            child: const Text('播放'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    _linkCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('搜索'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '源管理',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SourcesPage()),
              );
              _loadSources();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: glassBox(
                    radius: 24,
                    child: TextField(
                      controller: _keywordCtl,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _doSearch(),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: '搜片名',
                        prefixIcon: IconButton(
                          icon: const Icon(Icons.search, size: 20),
                          onPressed: _searching ? null : () => _doSearch(),
                        ),
                        suffixIcon: _keywordCtl.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _keywordCtl.clear();
                                  setState(() {
                                    _results = [];
                                    _status = '';
                                  });
                                },
                              ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                glassBox(
                  radius: 24,
                  child: IconButton(
                    icon: const Icon(Icons.link, size: 20),
                    tooltip: '粘贴链接直接播',
                    onPressed: _showLinkDialog,
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                for (final t in _types)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(t),
                      selected: _type == t,
                      onSelected: (_) => setState(() => _type = t),
                    ),
                  ),
                const SizedBox(width: 4),
                ActionChip(
                  avatar: const Icon(Icons.storage, size: 16),
                  label: Text(_onlySource ?? '全部源'),
                  onPressed: _pickSource,
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('只看国语'),
                  selected: _onlyMandarin,
                  onSelected: (v) => setState(() => _onlyMandarin = v),
                ),
              ],
            ),
          ),
          if (_history.isNotEmpty && _results.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  const Text('搜索历史', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.remove('search_history');
                      setState(() => _history = []);
                    },
                    child: const Text('清空', style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ),
                ],
              ),
            ),
          if (_history.isNotEmpty && _results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final h in _history)
                    ActionChip(
                      label: Text(h),
                      onPressed: () {
                        _keywordCtl.text = h;
                        _doSearch(h);
                      },
                    ),
                ],
              ),
            ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(_status, style: const TextStyle(color: Colors.grey)),
            ),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator(color: kYellow))
                : _shown.isEmpty
                    ? Center(
                        child: Text(
                          _results.isEmpty ? '搜片名开始看' : '这个类型下没结果，换个类型试试',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: posterGridAspect(context),
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 14,
                        ),
                        itemCount: _shown.length,
                        itemBuilder: (context, i) =>
                            VodCard(vod: _shown[i], onlyMandarin: _onlyMandarin),
                      ),
          ),
        ],
      ),
    );
  }
}

// ---------- 底部导航：首页 / 发现 / 搜索 / 收藏 / 我的 ----------

/// 保活壳：5 个 tab 常驻内存不销毁，切页秒开、不重新拉数据
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class MainNav extends StatefulWidget {
  const MainNav({super.key});
  @override
  State<MainNav> createState() => _MainNavState();
}

class _MainNavState extends State<MainNav> {
  int _index = 0;
  final _pageController = PageController();
  static const _labels = ['首页', '发现', '搜索', '收藏', '我的'];
  static const _icons = [Icons.home, Icons.explore, Icons.search, Icons.favorite, Icons.person];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    if (i == _index) return;
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Stack(
        children: [
          // 深绿渐变底，玻璃才有东西可折
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? const [Color(0xFF132019), Color(0xFF0B0F0C), Color(0xFF070707)]
                      : const [Color(0xFFF0F6F1), Color(0xFFFFFFFF)],
                  stops: isDark ? const [0.0, 0.55, 1.0] : const [0.0, 1.0],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: PageView(
              controller: _pageController,
              onPageChanged: (i) {
                setState(() => _index = i);
                HapticFeedback.selectionClick();
              },
              children: const [
                _KeepAlive(child: HomeFeedPage()),
                _KeepAlive(child: DiscoverPage()),
                _KeepAlive(child: SearchPage()),
                _KeepAlive(child: FavoritesPage()),
                _KeepAlive(child: ProfilePage()),
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: glassBox(
              radius: 28,
              opacity: isDark ? 0.22 : 0.75,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final tabW = constraints.maxWidth / 5;
                    return Stack(
                      children: [
                        // 滑动的液态玻璃 pill：跟着选中的 tab 走，带回弹
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 450),
                          curve: Curves.easeOutBack,
                          left: tabW * _index + 6,
                          top: 4,
                          bottom: 4,
                          width: tabW - 12,
                          child: glassBox(
                            radius: 20,
                            opacity: 0.45,
                            tint: kYellow,
                            child: const SizedBox.expand(),
                          ),
                        ),
                        Row(
                          children: List.generate(5, (i) {
                            final active = i == _index;
                            return Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _goTo(i),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AnimatedScale(
                                      scale: active ? 1.15 : 1.0,
                                      duration: const Duration(milliseconds: 250),
                                      child: Icon(_icons[i],
                                          color: active ? kYellow : Colors.grey, size: 24),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _labels[i],
                                      style: TextStyle(
                                        color: active ? kYellow : Colors.grey,
                                        fontSize: 11,
                                        fontWeight:
                                            active ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 首页：推荐分区 ----------

class FeedSectionData {
  final String title;
  final String filter;
  final List<Vod> items;
  FeedSectionData(this.title, this.filter, this.items);
}

class HomeFeedPage extends StatefulWidget {
  const HomeFeedPage({super.key});
  @override
  State<HomeFeedPage> createState() => _HomeFeedPageState();
}

class _HomeFeedPageState extends State<HomeFeedPage> {
  List<Map<String, String>> _sources = kSources;
  String _sourceName = '';
  String _base = '';
  List<FeedSectionData> _sections = [];
  List<Vod> _all = [];
  int _nextPg = 4;
  bool _loading = true;
  bool _loadingMore = false;
  bool _noMore = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await fetchRemoteSources();
    final list = await effectiveSources();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('selected_source') ?? '';
    if (!mounted) return;
    setState(() {
      _sources = list;
      if (saved.isNotEmpty && list.any((s) => s['name'] == saved)) {
        _sourceName = saved;
      }
    });
    await _loadFeed();
  }

  Future<void> _loadFeed() async {
    setState(() => _loading = true);
    final src = _sources.firstWhere(
      (s) => s['name'] == _sourceName,
      orElse: () => _sources.isNotEmpty ? _sources.first : {'name': '', 'url': ''},
    );
    final base = src['url'] ?? '';
    final name = src['name'] ?? '';
    List<Vod> all = [];
    if (base.isNotEmpty) {
      final pages = await Future.wait([
        fetchLatest(base, name, pg: 1).catchError((_) => <Vod>[]),
        fetchLatest(base, name, pg: 2).catchError((_) => <Vod>[]),
        fetchLatest(base, name, pg: 3).catchError((_) => <Vod>[]),
      ]);
      all = pages.expand((p) => p).toList();
    }
    if (!mounted) return;
    setState(() {
      _sourceName = name;
      _base = base;
      _loading = false;
      _all = all;
      _nextPg = 4;
      _noMore = false;
      _sections = _buildSections(all);
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _base.isEmpty) return;
    setState(() => _loadingMore = true);
    final pages = await Future.wait([
      fetchLatest(_base, _sourceName, pg: _nextPg).catchError((_) => <Vod>[]),
      fetchLatest(_base, _sourceName, pg: _nextPg + 1).catchError((_) => <Vod>[]),
      fetchLatest(_base, _sourceName, pg: _nextPg + 2).catchError((_) => <Vod>[]),
    ]);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      _nextPg += 3;
      _noMore = pages.every((p) => p.isEmpty);
      _all = [..._all, ...pages.expand((p) => p)];
      _sections = _buildSections(_all);
    });
  }

  List<FeedSectionData> _buildSections(List<Vod> all) {
    final seen = <String>{};
    final dedup = all.where((v) {
      final k = '${v.name}|${v.year}';
      if (seen.contains(k)) return false;
      seen.add(k);
      return true;
    }).toList();
    bool match(Vod v, List<String> keys) {
      final s = '${v.typeName} ${v.vodClass} ${v.name}';
      return keys.any(s.contains);
    }

    // 源站“最新”是按更新时间排的，老片重传也会排前面；
    // 这里改按上映年份倒序，2026/2025 的新片先出，同年内保持源站顺序
    int yearOf(Vod v) => int.tryParse(v.year) ?? 0;
    dedup.sort((a, b) => yearOf(b).compareTo(yearOf(a)));

    final out = <FeedSectionData>[];
    final rec = dedup.take(12).toList();
    if (rec.isNotEmpty) out.add(FeedSectionData('最新推荐', 'all', rec));
    final movie = dedup.where((v) => match(v, ['电影'])).take(12).toList();
    if (movie.length >= 2) out.add(FeedSectionData('电影', '电影', movie));
    final tv = dedup.where((v) => match(v, ['电视剧'])).take(12).toList();
    if (tv.length >= 2) out.add(FeedSectionData('电视剧', '电视剧', tv));
    final anime = dedup.where((v) => match(v, ['动漫', '动画', '国漫', '日漫'])).take(12).toList();
    if (anime.length >= 2) out.add(FeedSectionData('动漫', '动漫', anime));
    final variety = dedup.where((v) => match(v, ['综艺'])).take(12).toList();
    if (variety.length >= 2) out.add(FeedSectionData('综艺', '综艺', variety));
    return out;
  }

  void _switchSource() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('切换片源', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            for (final s in _sources)
              ListTile(
                title: Text(s['name']!),
                trailing:
                    s['name'] == _sourceName ? const Icon(Icons.check, color: kYellow) : null,
                onTap: () async {
                  Navigator.pop(context);
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('selected_source', s['name']!);
                  setState(() => _sourceName = s['name']!);
                  _loadFeed();
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _loadFeed,
              color: kYellow,
              child: CustomScrollView(
                cacheExtent: 800,
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: 64)),
                  if (_loading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: 120),
                        child: Center(child: CircularProgressIndicator(color: kYellow)),
                      ),
                    )
                  else if (_sections.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: 120),
                        child: Center(
                          child: Text('这个源暂时没有内容，换个源试试', style: TextStyle(color: Colors.grey)),
                        ),
                      ),
                    )
                  else
                    for (final sec in _sections) ...[
                      SliverToBoxAdapter(
                        child: sectionHeader(sec.title, onMore: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SectionListPage(
                                title: sec.title,
                                filter: sec.filter,
                                sourceName: _sourceName,
                              ),
                            ),
                          );
                        }),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverGrid(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: posterGridAspect(context),
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 14,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => VodCard(vod: sec.items[i]),
                            childCount: sec.items.length,
                          ),
                        ),
                      ),
                    ],
                  if (!_loading && _sections.isNotEmpty && !_noMore)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: Center(
                          child: _loadingMore
                              ? const CircularProgressIndicator(color: kYellow)
                              : OutlinedButton(
                                  onPressed: _loadMore,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: kYellow,
                                    side: const BorderSide(color: kYellow),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                  ),
                                  child: const Text('加载更多'),
                                ),
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 110)),
                ],
              ),
            ),
            Positioned(
              top: 10,
              left: 16,
              right: 16,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: _switchSource,
                      child: glassBox(
                        radius: 20,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: kYellow,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                _sourceName.isEmpty ? '影搜' : _sourceName,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.keyboard_arrow_down, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Text('首页', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 分区更多列表 ----------

class SectionListPage extends StatefulWidget {
  final String title;
  final String filter;
  final String sourceName;
  const SectionListPage(
      {super.key, required this.title, required this.filter, required this.sourceName});
  @override
  State<SectionListPage> createState() => _SectionListPageState();
}

class _SectionListPageState extends State<SectionListPage> {
  List<Vod> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sources = await effectiveSources();
    final prefs = await SharedPreferences.getInstance();
    final preferred = widget.sourceName.isNotEmpty
        ? widget.sourceName
        : (prefs.getString('selected_source') ?? '');
    final src = sources.firstWhere(
      (s) => s['name'] == preferred,
      orElse: () => sources.isNotEmpty ? sources.first : {'name': '', 'url': ''},
    );
    final base = src['url'] ?? '';
    List<Vod> all = [];
    if (base.isNotEmpty) {
      for (var pg = 1; pg <= 3; pg++) {
        final page = await fetchLatest(base, src['name'] ?? '', pg: pg).catchError((_) => <Vod>[]);
        all = [...all, ...page];
        if (all.length >= 30) break;
      }
    }
    bool match(Vod v) {
      if (widget.filter == 'all') return true;
      final keys =
          widget.filter == '动漫' ? ['动漫', '动画', '国漫', '日漫'] : [widget.filter];
      final s = '${v.typeName} ${v.vodClass} ${v.name}';
      return keys.any(s.contains);
    }

    final seen = <String>{};
    final items = all.where(match).where((v) {
      final k = '${v.name}|${v.year}';
      if (seen.contains(k)) return false;
      seen.add(k);
      return true;
    }).toList();
    // 和首页一样按上映年份倒序，新片先出
    int yearOf(Vod v) => int.tryParse(v.year) ?? 0;
    items.sort((a, b) => yearOf(b).compareTo(yearOf(a)));
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kYellow))
          : _items.isEmpty
              ? const Center(child: Text('没有更多了', style: TextStyle(color: Colors.grey)))
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: posterGridAspect(context),
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, i) => VodCard(vod: _items[i]),
                ),
    );
  }
}

// ---------- 发现：分类 ----------

class DiscoverPage extends StatelessWidget {
  const DiscoverPage({super.key});
  static const _cats = [
    ('电影', Icons.movie),
    ('电视剧', Icons.tv),
    ('动漫', Icons.animation),
    ('综艺', Icons.celebration),
    ('动作', Icons.bolt),
    ('喜剧', Icons.mood),
    ('爱情', Icons.favorite),
    ('科幻', Icons.rocket_launch),
    ('悬疑', Icons.psychology),
    ('恐怖', Icons.dark_mode),
    ('惊悚', Icons.warning_amber),
    ('战争', Icons.shield),
    ('国漫', Icons.flag),
    ('日漫', Icons.auto_stories),
    ('纪录片', Icons.video_library),
    ('犯罪', Icons.gavel),
    ('古装', Icons.account_balance),
    ('都市', Icons.location_city),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('发现')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('分类找片', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 10,
              children: [
                for (final (name, icon) in _cats)
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SectionListPage(
                            title: name,
                            filter: name,
                            sourceName: '',
                          ),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFEFEFEF),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 16, color: kYellow),
                          const SizedBox(width: 6),
                          Text(name, style: const TextStyle(fontSize: 14)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            const Text('点一个分类，直接看该类型的最新推荐',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

// ---------- 收藏 ----------

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});
  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  List<Vod> _favs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await readFavorites();
    if (!mounted) return;
    setState(() => _favs = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('收藏')),
      body: _favs.isEmpty
          ? const Center(
              child: Text('还没有收藏，看到喜欢的片点右上角的心',
                  style: TextStyle(color: Colors.grey)),
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: posterGridAspect(context),
                crossAxisSpacing: 12,
                mainAxisSpacing: 14,
              ),
              itemCount: _favs.length,
              itemBuilder: (context, i) => VodCard(vod: _favs[i]),
            ),
    );
  }
}

// ---------- 我的 ----------

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _theme = 'dark';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _theme = prefs.getString('theme_mode') ?? 'dark');
  }

  Future<void> _setTheme(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', v);
    setState(() => _theme = v);
    themeMode.value =
        v == 'light' ? ThemeMode.light : v == 'system' ? ThemeMode.system : ThemeMode.dark;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
        children: [
          const Text('外观', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          RadioListTile<String>(
            title: const Text('深色模式'),
            value: 'dark',
            groupValue: _theme,
            activeColor: kYellow,
            onChanged: (v) => _setTheme(v!),
          ),
          RadioListTile<String>(
            title: const Text('浅色模式'),
            value: 'light',
            groupValue: _theme,
            activeColor: kYellow,
            onChanged: (v) => _setTheme(v!),
          ),
          RadioListTile<String>(
            title: const Text('跟随系统'),
            value: 'system',
            groupValue: _theme,
            activeColor: kYellow,
            onChanged: (v) => _setTheme(v!),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('源管理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SourcesPage()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('从网上拉取最新源'),
            onTap: () async {
              final r = await fetchRemoteSources();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(r == null ? '拉取失败，用的还是上次的源' : '源列表已更新到最新')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('清空搜索历史'),
            onTap: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('search_history');
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空')));
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('清空收藏'),
            onTap: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('favorites_json');
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空')));
            },
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text('影搜 v1.0 · 片源来自公开采集站', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ---------- 详情页：选线路和选集 ----------

class DetailPage extends StatefulWidget {
  final Vod vod;
  final bool onlyMandarin;
  const DetailPage({super.key, required this.vod, required this.onlyMandarin});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  List<PlayLine> _lines = [];
  String _blurb = '';
  bool _loadingLines = true;
  String? _linesError;
  int _lineIndex = 0;
  int _resumeIndex = -1;
  bool _fav = false;
  bool _blurbExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadLines();
    isFavorite(widget.vod).then((v) {
      if (mounted) setState(() => _fav = v);
    });
  }

  Future<void> _loadLines() async {
    final res = await fetchLines(widget.vod.sourceUrl, widget.vod.id)
        .catchError((_) => (lines: <PlayLine>[], blurb: ''));
    if (!mounted) return;
    setState(() {
      _lines = filterMandarin(res.lines, widget.onlyMandarin);
      _blurb = res.blurb;
      _loadingLines = false;
      if (_lines.isEmpty) _linesError = '这个源没有可播的线路，换个源搜搜';
    });
    _checkResume();
  }

  /// 找到上次看到哪一集（有断点记录的最后一集）
  Future<void> _checkResume() async {
    if (_lines.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final line = _lines[_lineIndex >= _lines.length ? _lines.length - 1 : _lineIndex];
    var found = -1;
    for (var i = 0; i < line.episodes.length; i++) {
      final key = 'pos_${widget.vod.name}_${line.name}_${line.episodes[i].name}';
      if ((prefs.getInt(key) ?? 0) > 0) found = i;
    }
    if (!mounted) return;
    setState(() => _resumeIndex = found);
  }

  Future<void> _toggleFav() async {
    final nowFav = await toggleFavorite(widget.vod);
    if (!mounted) return;
    setState(() => _fav = nowFav);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowFav ? '已收藏' : '已取消收藏'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _playEpisode(int index) {
    final safeIndex = _lineIndex >= _lines.length ? _lines.length - 1 : _lineIndex;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          title: widget.vod.name,
          lines: _lines,
          lineIndex: safeIndex,
          episodeIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vod = widget.vod;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final line = _lines.isEmpty
        ? null
        : _lines[_lineIndex >= _lines.length ? _lines.length - 1 : _lineIndex];
    final playIndex = _resumeIndex >= 0 ? _resumeIndex : 0;
    final playLabel = _resumeIndex >= 0 && line != null
        ? '继续播放 · ${line.episodes[_resumeIndex].name}'
        : '立即播放';
    return Scaffold(
      appBar: AppBar(
        title: Text(vod.name),
        actions: [
          IconButton(
            icon: Icon(_fav ? Icons.favorite : Icons.favorite_border,
                color: _fav ? kYellow : null),
            tooltip: '收藏',
            onPressed: _toggleFav,
          ),
        ],
      ),
      body: _loadingLines
          ? const Center(child: CircularProgressIndicator(color: kYellow))
          : _linesError != null || line == null
              ? Center(child: Text(_linesError ?? '没有可播的线路'))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: () => _playEpisode(playIndex),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: vod.pic.isEmpty
                                      ? Container(
                                          width: 110,
                                          height: 150,
                                          color: const Color(0xFF242424),
                                          child: const Icon(Icons.movie, color: Colors.grey),
                                        )
                                      : CachedNetworkImage(
                                          imageUrl: vod.pic,
                                          memCacheWidth: 400,
                                          memCacheHeight: 550,
                                          width: 110,
                                          height: 150,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, __, ___) => Container(
                                            width: 110,
                                            height: 150,
                                            color: const Color(0xFF242424),
                                            child: const Icon(Icons.broken_image,
                                                color: Colors.grey),
                                          ),
                                        ),
                                ),
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.45),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.play_arrow,
                                      color: kYellow, size: 28),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(vod.name,
                                    style: const TextStyle(
                                        fontSize: 19, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 6),
                                Text(
                                    [vod.year, vod.area, vod.typeName]
                                        .where((e) => e.isNotEmpty)
                                        .join(' · '),
                                    style: const TextStyle(color: Colors.grey)),
                                if (vod.remarks.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(vod.remarks,
                                      style: const TextStyle(color: Colors.grey)),
                                ],
                                const SizedBox(height: 4),
                                Text('来源：${vod.source}',
                                    style: const TextStyle(color: Colors.grey)),
                                if (vod.vodClass.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(vod.vodClass,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.grey)),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _playEpisode(playIndex),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(playLabel,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                          style: FilledButton.styleFrom(
                            backgroundColor: kYellow,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ),
                    if (_blurb.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Text('简介', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                        child: GestureDetector(
                          onTap: () => setState(() => _blurbExpanded = !_blurbExpanded),
                          child: Text(
                            _blurb,
                            maxLines: _blurbExpanded ? null : 3,
                            overflow: _blurbExpanded
                                ? TextOverflow.visible
                                : TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.grey, height: 1.5),
                          ),
                        ),
                      ),
                    ],
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Text('线路', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Row(
                        children: [
                          for (var i = 0; i < _lines.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(_lines[i].name),
                                selected: i == _lineIndex,
                                onSelected: (_) {
                                  setState(() => _lineIndex = i);
                                  _checkResume();
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Text('选集 · 共 ${line.episodes.length} 集',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          childAspectRatio: 2.4,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: line.episodes.length,
                        itemBuilder: (context, i) {
                          final ep = line.episodes[i];
                          final isResume = i == _resumeIndex;
                          return GestureDetector(
                            onTap: () => _playEpisode(i),
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isResume
                                    ? kYellow
                                    : (isDark
                                        ? const Color(0xFF1E1E1E)
                                        : const Color(0xFFEFEFEF)),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                ep.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isResume ? Colors.black : null,
                                  fontWeight:
                                      isResume ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ---------- 源管理：远程自动更新 + 自加源 ----------

class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key});
  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  List<Map<String, String>> _base = [];
  List<Map<String, String>> _custom = [];
  Set<String> _disabled = {};
  String _updatedAt = '';
  bool _refreshing = false;
  final _nameCtl = TextEditingController();
  final _urlCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final base = await readBaseSources();
    final custom = await readCustomSources();
    final disabled = await readDisabledUrls();
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt('remote_sources_updated_at');
    if (!mounted) return;
    setState(() {
      _base = base;
      _custom = custom;
      _disabled = disabled.toSet();
      _updatedAt = ts == null
          ? '还没有从网上拉取过'
          : '上次更新：${DateTime.fromMillisecondsSinceEpoch(ts).toString().substring(0, 16)}';
    });
  }

  Future<void> _refreshRemote() async {
    setState(() => _refreshing = true);
    final remote = await fetchRemoteSources();
    await _reload();
    if (!mounted) return;
    setState(() => _refreshing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(remote == null ? '拉取失败，用的还是上次的源' : '源列表已更新到最新')),
    );
  }

  Future<void> _toggle(String url, bool on) async {
    final prefs = await SharedPreferences.getInstance();
    final next = Set<String>.from(_disabled);
    if (on) {
      next.remove(url);
    } else {
      next.add(url);
    }
    await prefs.setStringList('disabled_source_urls', next.toList());
    setState(() => _disabled = next);
  }

  Future<void> _addCustom() async {
    final name = _nameCtl.text.trim();
    final url = _urlCtl.text.trim();
    if (name.isEmpty || !url.startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名字和链接都要填，链接要以 http 开头')),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final list = await readCustomSources();
    if (!mounted) return;
    if (list.any((s) => s['url'] == url)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这个源已经加过了')));
      return;
    }
    list.add({'name': name, 'url': url});
    await prefs.setString('custom_sources_json', jsonEncode(list));
    _nameCtl.clear();
    _urlCtl.clear();
    await _reload();
  }

  Future<void> _removeCustom(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await readCustomSources();
    list.removeWhere((s) => s['url'] == url);
    await prefs.setString('custom_sources_json', jsonEncode(list));
    await _reload();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _urlCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('源管理')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(_updatedAt, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _refreshing ? null : _refreshRemote,
            child: Text(_refreshing ? '正在拉取…' : '从网上拉取最新源'),
          ),
          const SizedBox(height: 16),
          const Text('官方源', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final s in _base)
            SwitchListTile(
              title: Text(s['name']!),
              subtitle: Text(s['url']!, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              value: !_disabled.contains(s['url']),
              onChanged: (v) => _toggle(s['url']!, v),
            ),
          const SizedBox(height: 8),
          const Text('自己加的源', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final s in _custom)
            ListTile(
              title: Text(s['name']!),
              subtitle: Text(s['url']!, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => _removeCustom(s['url']!),
              ),
            ),
          const SizedBox(height: 16),
          const Text('添加新源', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtl,
            decoration: const InputDecoration(
              hintText: '源名字，比如 光速',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtl,
            decoration: const InputDecoration(
              hintText: '源地址，以 https 开头，到 /vod/ 为止',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _addCustom, child: const Text('添加')),
          const SizedBox(height: 8),
          const Text(
            '源地址是苹果 CMS 的接口地址，一般以 /api.php/provide/vod/ 结尾。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ---------- 播放页（开源 Chewie，干净简洁） ----------

class PlayerPage extends StatefulWidget {
  final String title;
  final List<PlayLine> lines;
  final int lineIndex;
  final int episodeIndex;
  final String? directUrl;
  const PlayerPage({
    super.key,
    required this.title,
    this.lines = const [],
    this.lineIndex = 0,
    this.episodeIndex = 0,
    this.directUrl,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  String? _error;
  int _tryIndex = 0;
  int _tryTotal = 1;

  // 手势状态：长按加速 / 双击快进快退 / 横滑进度 / 竖滑亮度音量
  double? _savedRate;
  String? _gestureHint;
  Timer? _hintTimer;
  double? _dragStartBrightness;
  double? _dragStartVolume;
  bool _brightnessTouched = false;
  Offset? _doubleTapPos;

  Episode? get _episode {
    if (widget.lines.isEmpty) return null;
    final eps = widget.lines[widget.lineIndex].episodes;
    if (widget.episodeIndex >= eps.length) return null;
    return eps[widget.episodeIndex];
  }

  String get _resumeKey {
    if (widget.directUrl != null) return widget.directUrl!;
    final ep = _episode;
    return '${widget.title}_${widget.lines[widget.lineIndex].name}_${ep?.name ?? ''}';
  }

  String get _currentUrl {
    if (widget.directUrl != null) return widget.directUrl!;
    return _episode?.url ?? '';
  }

  bool get _hasNext {
    if (widget.lines.isEmpty) return false;
    return widget.episodeIndex + 1 < widget.lines[widget.lineIndex].episodes.length;
  }

  /// 同一集在各条线路的地址，播不了自动换下一条
  List<String> _candidates() {
    if (widget.directUrl != null) return [widget.directUrl!];
    final ep = _episode;
    if (ep == null) return [];
    final urls = <String>[];
    for (final l in widget.lines) {
      final same = l.episodes.where((e) => e.name == ep.name).toList();
      if (same.isNotEmpty) {
        urls.add(same.first.url);
      } else if (l.episodes.length > widget.episodeIndex) {
        urls.add(l.episodes[widget.episodeIndex].url);
      }
    }
    final seen = <String>{};
    return urls.where((u) => u.isNotEmpty && seen.add(u)).toList();
  }

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final candidates = _candidates();
    _tryTotal = candidates.length;
    for (var i = 0; i < candidates.length; i++) {
      if (!mounted) return;
      setState(() => _tryIndex = i);
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(candidates[i]),
        httpHeaders: const {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        },
      );
      try {
        await controller.initialize().timeout(const Duration(seconds: 15));
        final prefs = await SharedPreferences.getInstance();
        final savedMs = prefs.getInt('pos_$_resumeKey') ?? 0;
        if (savedMs > 0 && savedMs < controller.value.duration.inMilliseconds) {
          await controller.seekTo(Duration(milliseconds: savedMs));
        }
        await controller.play();
        if (!mounted) return;
        final chewie = ChewieController(
          videoPlayerController: controller,
          autoPlay: true,
          allowFullScreen: true,
          allowMuting: true,
          allowPlaybackSpeedChanging: true,
          playbackSpeeds: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0],
          materialProgressColors: ChewieProgressColors(
            playedColor: kYellow,
            handleColor: kYellow,
            backgroundColor: Colors.white24,
            bufferedColor: Colors.white38,
          ),
          cupertinoProgressColors: ChewieProgressColors(
            playedColor: kYellow,
            handleColor: kYellow,
            backgroundColor: Colors.white24,
            bufferedColor: Colors.white38,
          ),
        );
        setState(() {
          _videoController = controller;
          _chewieController = chewie;
        });
        return;
      } catch (_) {
        await controller.dispose();
      }
    }
    if (!mounted) return;
    setState(() => _error = '这几条线路都播不了，换个源搜搜看');
  }

  Future<void> _savePosition() async {
    final c = _videoController;
    if (c == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pos_$_resumeKey', c.value.position.inMilliseconds);
  }

  void _nextEpisode() {
    if (!_hasNext) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          title: widget.title,
          lines: widget.lines,
          lineIndex: widget.lineIndex,
          episodeIndex: widget.episodeIndex + 1,
        ),
      ),
    );
  }

  // ---------- 播放手势 ----------

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _showHint(String text, {bool sticky = false}) {
    _hintTimer?.cancel();
    setState(() => _gestureHint = text);
    if (!sticky) {
      _hintTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _gestureHint = null);
      });
    }
  }

  void _clearHint() {
    _hintTimer?.cancel();
    if (mounted) setState(() => _gestureHint = null);
  }

  void _hideHintSoon() {
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _gestureHint = null);
    });
  }

  Future<void> _seekBy(Duration d) async {
    final c = _videoController;
    if (c == null) return;
    final pos = c.value.position + d;
    final total = c.value.duration;
    final target = pos < Duration.zero
        ? Duration.zero
        : (pos > total ? total : pos);
    await c.seekTo(target);
  }

  /// 长按左右任意一边：3 倍速快进，松手恢复
  void _onLongPressStart(LongPressStartDetails _) {
    final c = _videoController;
    if (c == null) return;
    _savedRate = c.value.playbackSpeed;
    c.setPlaybackSpeed(3.0);
    _showHint('3.0x 快进中', sticky: true);
  }

  void _onLongPressEnd() {
    final c = _videoController;
    if (c != null && _savedRate != null) c.setPlaybackSpeed(_savedRate!);
    _savedRate = null;
    _clearHint();
  }

  /// 双击左边后退 10 秒，右边快进 10 秒
  void _onDoubleTap() {
    final c = _videoController;
    if (c == null || _doubleTapPos == null) return;
    final w = MediaQuery.of(context).size.width;
    if (_doubleTapPos!.dx < w / 2) {
      _seekBy(const Duration(seconds: -10));
      _showHint('−10秒');
    } else {
      _seekBy(const Duration(seconds: 10));
      _showHint('+10秒');
    }
  }

  /// 竖滑：左边调亮度，右边调音量
  void _onVerticalDragStart(DragStartDetails d) async {
    final w = MediaQuery.of(context).size.width;
    if (d.globalPosition.dx < w / 2) {
      _dragStartBrightness =
          await ScreenBrightness().application.catchError((_) => 0.5);
    } else {
      _dragStartVolume =
          await VolumeController.instance.getVolume().catchError((_) => 0.5);
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) async {
    final w = MediaQuery.of(context).size.width;
    final delta = -d.delta.dy / 300;
    if (d.globalPosition.dx < w / 2) {
      final v = ((_dragStartBrightness ?? 0.5) + delta).clamp(0.05, 1.0);
      _dragStartBrightness = v;
      _brightnessTouched = true;
      await ScreenBrightness().setApplicationScreenBrightness(v);
      _showHint('亮度 ${(v * 100).round()}%', sticky: true);
    } else {
      final v = ((_dragStartVolume ?? 0.5) + delta).clamp(0.0, 1.0);
      _dragStartVolume = v;
      await VolumeController.instance.setVolume(v);
      _showHint('音量 ${(v * 100).round()}%', sticky: true);
    }
  }

  /// 横滑：拖进度
  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    final c = _videoController;
    if (c == null) return;
    final total = c.value.duration.inMilliseconds;
    if (total <= 0) return;
    final w = MediaQuery.of(context).size.width;
    final deltaMs = (d.delta.dx / w * total * 0.25).round();
    final target =
        (c.value.position.inMilliseconds + deltaMs).clamp(0, total);
    c.seekTo(Duration(milliseconds: target));
    _showHint('${_fmt(Duration(milliseconds: target))} / ${_fmt(c.value.duration)}',
        sticky: true);
  }

  void _showEpisodes() {
    if (widget.lines.isEmpty) return;
    final eps = widget.lines[widget.lineIndex].episodes;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选集', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  childAspectRatio: 2.4,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: eps.length,
                itemBuilder: (context, i) {
                  final current = i == widget.episodeIndex;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      if (i == widget.episodeIndex) return;
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PlayerPage(
                            title: widget.title,
                            lines: widget.lines,
                            lineIndex: widget.lineIndex,
                            episodeIndex: i,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: current ? kYellow : const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        eps[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: current ? Colors.black : Colors.white,
                          fontWeight:
                              current ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 画质就是线路：不同线路对应不同片源与清晰度，播不了就换一条
  void _showLines() {
    if (widget.lines.isEmpty) return;
    final curEpName = _episode?.name ?? '';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child:
                  Text('画质 · 线路', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('不同线路对应不同片源与清晰度，播不了就换一条',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
            ),
            for (var i = 0; i < widget.lines.length; i++)
              ListTile(
                title: Text(widget.lines[i].name),
                subtitle: Text(_lineQuality(i)),
                trailing: i == widget.lineIndex
                    ? const Icon(Icons.check, color: kYellow)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  if (i == widget.lineIndex) return;
                  final target = widget.lines[i];
                  var epIndex = widget.episodeIndex;
                  final byName =
                      target.episodes.indexWhere((e) => e.name == curEpName);
                  if (byName >= 0) {
                    epIndex = byName;
                  } else if (epIndex >= target.episodes.length) {
                    epIndex = target.episodes.length - 1;
                  }
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PlayerPage(
                        title: widget.title,
                        lines: widget.lines,
                        lineIndex: i,
                        episodeIndex: epIndex,
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  String _lineQuality(int li) {
    final eps = widget.lines[li].episodes;
    final curName = _episode?.name ?? '';
    Episode? ep;
    for (final e in eps) {
      if (e.name == curName) {
        ep = e;
        break;
      }
    }
    ep ??= widget.episodeIndex < eps.length
        ? eps[widget.episodeIndex]
        : (eps.isEmpty ? null : eps.first);
    final q = ep == null ? '' : qualityOf(ep.name);
    return q.isEmpty ? '${eps.length} 集' : '$q · ${eps.length} 集';
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    if (_brightnessTouched) {
      ScreenBrightness().resetApplicationScreenBrightness();
    }
    _savePosition();
    _chewieController?.dispose();
    _videoController?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ep = _episode;
    final title = widget.directUrl != null
        ? widget.title
        : '${widget.title} ${ep?.name ?? ''}';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.grid_view),
            tooltip: '选集',
            onPressed: _showEpisodes,
          ),
          IconButton(
            icon: const Icon(Icons.high_quality),
            tooltip: '画质 · 线路',
            onPressed: _showLines,
          ),
          if (_hasNext)
            IconButton(
              icon: const Icon(Icons.skip_next),
              tooltip: '下一集',
              onPressed: _nextEpisode,
            ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制播放链接',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _currentUrl));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('链接已复制')));
            },
          ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 12),
                    const Text('换条线路试试，或者复制链接到别的播放器',
                        style: TextStyle(color: Colors.grey)),
                  ],
                ),
              )
            : _chewieController == null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: kYellow),
                      const SizedBox(height: 12),
                      Text(
                        _tryTotal > 1
                            ? '正在试第 ${_tryIndex + 1}/$_tryTotal 条线路…'
                            : '正在加载…',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      Chewie(controller: _chewieController!),
                      // 手势层：盖住画面区，留出底部控制条
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        bottom: 90,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onLongPressStart: _onLongPressStart,
                          onLongPressEnd: (_) => _onLongPressEnd(),
                          onLongPressCancel: _onLongPressEnd,
                          onDoubleTapDown: (d) => _doubleTapPos = d.globalPosition,
                          onDoubleTap: _onDoubleTap,
                          onVerticalDragStart: _onVerticalDragStart,
                          onVerticalDragUpdate: _onVerticalDragUpdate,
                          onVerticalDragEnd: (_) => _hideHintSoon(),
                          onHorizontalDragUpdate: _onHorizontalDragUpdate,
                          onHorizontalDragEnd: (_) => _hideHintSoon(),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      if (_gestureHint != null)
                        IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _gestureHint!,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}
