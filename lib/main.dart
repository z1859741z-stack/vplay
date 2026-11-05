import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() {
  runApp(const VPlayApp());
}

class VPlayApp extends StatelessWidget {
  const VPlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '影搜',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF141414),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1F1F),
          foregroundColor: Colors.white,
        ),
        colorScheme: const ColorScheme.dark(primary: Colors.redAccent),
      ),
      home: const HomePage(),
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

Future<List<PlayLine>> fetchLines(String base, String vodId) async {
  final uri = Uri.parse('$base?ac=detail&ids=$vodId');
  final resp = await http.get(uri).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) return [];
  final data = jsonDecode(resp.body);
  final list = (data['list'] as List?) ?? [];
  if (list.isEmpty) return [];
  final playUrl = '${(list[0] as Map<String, dynamic>)['vod_play_url'] ?? ''}';
  return parsePlayUrl(playUrl);
}

// vod_play_url 格式：线路名$第01集$url#第02集$url$$$线路2$...
List<PlayLine> parsePlayUrl(String playUrl) {
  final lines = <PlayLine>[];
  for (final part in playUrl.split('\$\$\$')) {
    if (part.trim().isEmpty) continue;
    final dollar = part.indexOf('\$');
    if (dollar < 0) continue;
    final lineName = part.substring(0, dollar);
    final rest = part.substring(dollar + 1);
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

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (d.inHours > 0) return '${d.inHours}:$m:$s';
  return '$m:$s';
}

// ---------- 首页：搜索 ----------

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _keywordCtl = TextEditingController();
  final _linkCtl = TextEditingController();
  String? _onlySource;
  bool _onlyMandarin = true;
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
        builder: (_) => PlayerPage(title: '直接播放', episodeName: '直链', url: url, resumeKey: url),
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
      appBar: AppBar(
        title: const Text('影搜'),
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
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keywordCtl,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _doSearch(),
                    decoration: InputDecoration(
                      hintText: '搜片名，比如 哪吒',
                      filled: true,
                      fillColor: const Color(0xFF242424),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _searching ? null : () => _doSearch(), child: const Text('搜索')),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部源'),
                  selected: _onlySource == null,
                  onSelected: (_) => setState(() => _onlySource = null),
                ),
                const SizedBox(width: 6),
                for (final s in _sources)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(s['name']!),
                      selected: _onlySource == s['name'],
                      onSelected: (_) => setState(() => _onlySource = s['name']),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Text('只看国语'),
                Switch(
                  value: _onlyMandarin,
                  onChanged: (v) => setState(() => _onlyMandarin = v),
                ),
                const Spacer(),
                if (_history.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.remove('search_history');
                      setState(() => _history = []);
                    },
                    child: const Text('清空历史'),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _linkCtl,
                    decoration: InputDecoration(
                      hintText: '粘贴 m3u8 / mp4 链接直接播',
                      filled: true,
                      fillColor: const Color(0xFF242424),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _playLink, child: const Text('播放')),
              ],
            ),
          ),
          if (_history.isNotEmpty && _results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
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
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? const Center(
                        child: Text('搜片名开始看', style: TextStyle(color: Colors.grey)),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 0.68,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: _results.length,
                        itemBuilder: (context, i) {
                          final v = _results[i];
                          return GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => DetailPage(vod: v, onlyMandarin: _onlyMandarin),
                                ),
                              );
                            },
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: v.pic.isEmpty
                                        ? Container(
                                            color: const Color(0xFF242424),
                                            child: const Center(
                                              child: Icon(Icons.movie, size: 40, color: Colors.grey),
                                            ),
                                          )
                                        : CachedNetworkImage(
                                            imageUrl: v.pic,
                                            fit: BoxFit.cover,
                                            width: double.infinity,
                                            placeholder: (_, __) => Container(
                                              color: const Color(0xFF242424),
                                              child: const Center(
                                                child: CircularProgressIndicator(strokeWidth: 2),
                                              ),
                                            ),
                                            errorWidget: (_, __, ___) => Container(
                                              color: const Color(0xFF242424),
                                              child: const Center(
                                                child: Icon(Icons.broken_image, color: Colors.grey),
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  v.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                Text(
                                  [v.year, v.remarks].where((e) => e.isNotEmpty).join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
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

// ---------- 详情页：选线路和选集 ----------

class DetailPage extends StatefulWidget {
  final Vod vod;
  final bool onlyMandarin;
  const DetailPage({super.key, required this.vod, required this.onlyMandarin});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late Future<List<PlayLine>> _future;
  int _lineIndex = 0;

  @override
  void initState() {
    super.initState();
    _future = fetchLines(widget.vod.sourceUrl, widget.vod.id);
  }

  @override
  Widget build(BuildContext context) {
    final vod = widget.vod;
    return Scaffold(
      appBar: AppBar(title: Text(vod.name)),
      body: FutureBuilder<List<PlayLine>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('拉取失败：${snap.error}'));
          }
          final lines = filterMandarin(snap.data ?? [], widget.onlyMandarin);
          if (lines.isEmpty) {
            return const Center(child: Text('这个源没有可播的线路，换个源搜搜'));
          }
          final safeIndex = _lineIndex >= lines.length ? lines.length - 1 : _lineIndex;
          final line = lines[safeIndex];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: vod.pic.isEmpty
                          ? Container(
                              width: 90,
                              height: 120,
                              color: const Color(0xFF242424),
                              child: const Icon(Icons.movie, color: Colors.grey),
                            )
                          : CachedNetworkImage(
                              imageUrl: vod.pic,
                              width: 90,
                              height: 120,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Container(
                                width: 90,
                                height: 120,
                                color: const Color(0xFF242424),
                                child: const Icon(Icons.broken_image, color: Colors.grey),
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(vod.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text([vod.year, vod.area, vod.typeName].where((e) => e.isNotEmpty).join(' · '),
                              style: const TextStyle(color: Colors.grey)),
                          if (vod.remarks.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(vod.remarks, style: const TextStyle(color: Colors.grey)),
                          ],
                          const SizedBox(height: 4),
                          Text('来源：${vod.source}', style: const TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('线路', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    for (var i = 0; i < lines.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(lines[i].name),
                          selected: i == _lineIndex,
                          onSelected: (_) => setState(() => _lineIndex = i),
                        ),
                      ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('选集', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 2.2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: line.episodes.length,
                  itemBuilder: (context, i) {
                    final ep = line.episodes[i];
                    final q = qualityOf(ep.name);
                    return FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () {
                        // 同一集在各条线路的地址都带上，播不了自动换下一条
                        final candidates = <String>[];
                        for (final l in lines) {
                          final same = l.episodes.where((e) => e.name == ep.name).toList();
                          if (same.isNotEmpty) {
                            candidates.add(same.first.url);
                          } else if (l.episodes.length > i) {
                            candidates.add(l.episodes[i].url);
                          }
                        }
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PlayerPage(
                              title: vod.name,
                              episodeName: ep.name,
                              url: ep.url,
                              urls: candidates,
                              resumeKey: '${vod.id}_${line.name}_${ep.name}',
                            ),
                          ),
                        );
                      },
                      child: Text(
                        q.isEmpty ? ep.name : '${ep.name} · $q',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
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

// ---------- 播放页 ----------

class PlayerPage extends StatefulWidget {
  final String title;
  final String episodeName;
  final String url;
  final List<String> urls;
  final String resumeKey;
  const PlayerPage({
    super.key,
    required this.title,
    required this.episodeName,
    required this.url,
    List<String>? urls,
    required this.resumeKey,
  }) : urls = urls ?? const [];


  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _controller;
  String? _error;
  bool _showControls = true;
  Timer? _hideTimer;
  int _tryIndex = 0;
  int _tryTotal = 1;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  List<String> get _candidates {
    final list = <String>[widget.url, ...widget.urls];
    final seen = <String>{};
    return list.where((u) => u.isNotEmpty && seen.add(u)).toList();
  }

  Future<void> _initPlayer() async {
    final candidates = _candidates;
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
        final savedMs = prefs.getInt('pos_${widget.resumeKey}') ?? 0;
        if (savedMs > 0 && savedMs < controller.value.duration.inMilliseconds) {
          await controller.seekTo(Duration(milliseconds: savedMs));
        }
        await controller.play();
        if (!mounted) return;
        setState(() => _controller = controller);
        _armHideTimer();
        return;
      } catch (_) {
        await controller.dispose();
      }
    }
    if (!mounted) return;
    setState(() => _error = '这几条线路都播不了，换个源搜搜看');
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  Future<void> _savePosition() async {
    final c = _controller;
    if (c == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pos_${widget.resumeKey}', c.value.position.inMilliseconds);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _savePosition();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${widget.title} ${widget.episodeName}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制播放链接',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.url));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('链接已复制')));
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
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    const Text('换条线路试试，或者复制链接到别的播放器', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              )
            : c == null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(
                        _tryTotal > 1
                            ? '正在试第 ${_tryIndex + 1}/$_tryTotal 条线路…'
                            : '正在加载…',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  )
                : GestureDetector(
                    onTap: () {
                      setState(() => _showControls = !_showControls);
                      if (_showControls) _armHideTimer();
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AspectRatio(
                          aspectRatio: c.value.aspectRatio,
                          child: VideoPlayer(c),
                        ),
                        if (_showControls)
                          Container(
                            color: Colors.black45,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      iconSize: 40,
                                      icon: const Icon(Icons.replay_10),
                                      onPressed: () {
                                        final pos = c.value.position - const Duration(seconds: 10);
                                        c.seekTo(pos < Duration.zero ? Duration.zero : pos);
                                      },
                                    ),
                                    const SizedBox(width: 24),
                                    IconButton(
                                      iconSize: 56,
                                      icon: Icon(
                                        c.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          if (c.value.isPlaying) {
                                            c.pause();
                                          } else {
                                            c.play();
                                          }
                                        });
                                        _armHideTimer();
                                      },
                                    ),
                                    const SizedBox(width: 24),
                                    IconButton(
                                      iconSize: 40,
                                      icon: const Icon(Icons.forward_10),
                                      onPressed: () {
                                        final pos = c.value.position + const Duration(seconds: 10);
                                        final dur = c.value.duration;
                                        c.seekTo(pos > dur ? dur : pos);
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: Row(
                                    children: [
                                      Text(_fmt(c.value.position)),
                                      Expanded(
                                        child: Slider(
                                          value: c.value.position.inMilliseconds.toDouble(),
                                          max: c.value.duration.inMilliseconds.toDouble() > 0
                                              ? c.value.duration.inMilliseconds.toDouble()
                                              : 1,
                                          onChanged: (v) {
                                            c.seekTo(Duration(milliseconds: v.toInt()));
                                          },
                                        ),
                                      ),
                                      Text(_fmt(c.value.duration)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
      ),
    );
  }
}
