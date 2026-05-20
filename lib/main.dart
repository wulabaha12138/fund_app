import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const FundApp());
}

class FundApp extends StatelessWidget {
  const FundApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '基金净值预估',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF1F3F5),
      ),
      home: const HomePage(),
    );
  }
}

const Color kRedUp = Color(0xFFEF4444);
const Color kGreenDown = Color(0xFF10B981);
const Color kTextMuted = Color(0xFF64748B);
const Color kCardBg = Color(0xFFFFFFFF);
const Color kBorder = Color(0xFFE2E8F0);

// ---- Models ----
class StockHolding {
  final String name;
  final String code;
  final double pct;
  final double? change;
  final String? errorMsg;
  StockHolding({required this.name, required this.code, required this.pct, this.change, this.errorMsg});
}

class FundData {
  final String fundName;
  final String fundCode;
  final String? nav;
  final String? navDate;
  final double estimatedChange;
  final double? estimatedNav;
  final double? actualChange;
  final bool isFinal;
  final List<StockHolding> holdings;
  final double totalPct;
  final String updateTime;
  final String status;
  final String? networkError;
  FundData({
    required this.fundName,
    required this.fundCode,
    this.nav,
    this.navDate,
    required this.estimatedChange,
    this.estimatedNav,
    this.actualChange,
    required this.isFinal,
    required this.holdings,
    required this.totalPct,
    required this.updateTime,
    required this.status,
    this.networkError,
  });
}

// 持久化存储的基金项
class SavedFund {
  String code;
  double amount;
  SavedFund({required this.code, this.amount = 0.0});

  Map<String, dynamic> toJson() => {'code': code, 'amount': amount};
  factory SavedFund.fromJson(Map<String, dynamic> j) => SavedFund(code: j['code'] as String, amount: (j['amount'] as num).toDouble());
}

// ---- API ----
class FundApi {
  static const _timeout = Duration(seconds: 20);
  static const _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';

  static Future<String> _get(String url, {Map<String, String>? headers}) async {
    headers ??= {
      'User-Agent': _userAgent,
      'Referer': 'https://fund.eastmoney.com/',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Accept-Encoding': 'gzip, deflate',
      'Connection': 'keep-alive',
    };
    final httpUrl = url.replaceFirst(RegExp(r'^https://'), 'http://');
    try {
      final client = http.Client();
      final response = await client.get(Uri.parse(httpUrl), headers: headers).timeout(_timeout);
      if (response.statusCode == 200) return utf8.decode(response.bodyBytes);
    } catch (_) {}
    final httpsUrl = url.replaceFirst(RegExp(r'^http://'), 'https://');
    final client = http.Client();
    try {
      final response = await client.get(Uri.parse(httpsUrl), headers: headers).timeout(_timeout);
      if (response.statusCode == 200) return utf8.decode(response.bodyBytes);
      throw Exception('HTTP ${response.statusCode}');
    } finally {
      client.close();
    }
  }

  static Future<Uint8List> _getBytes(String url, {Map<String, String>? headers}) async {
    headers ??= {'User-Agent': _userAgent, 'Referer': 'https://fund.eastmoney.com/', 'Accept': '*/*'};
    final httpUrl = url.replaceFirst(RegExp(r'^https://'), 'http://');
    try {
      final client = http.Client();
      final response = await client.get(Uri.parse(httpUrl), headers: headers).timeout(_timeout);
      if (response.statusCode == 200) return response.bodyBytes;
    } catch (_) {}
    final httpsUrl = url.replaceFirst(RegExp(r'^http://'), 'https://');
    final client = http.Client();
    try {
      final response = await client.get(Uri.parse(httpsUrl), headers: headers).timeout(_timeout);
      if (response.statusCode == 200) return response.bodyBytes;
      throw Exception('HTTP ${response.statusCode}');
    } finally {
      client.close();
    }
  }

  static String getSessionLabel() {
    final now = DateTime.now();
    if (now.weekday > 5) return '休市';
    final t = now.hour * 60 + now.minute;
    if (t < 9 * 60 + 30) return '未开市';
    if (t <= 11 * 60 + 30) return '交易中';
    if (t < 13 * 60) return '午休';
    if (t <= 15 * 60) return '交易中';
    return '已收盘';
  }

  static bool isSameDay(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return false;
    try {
      final parsed = DateFormat('yyyy-MM-dd').parseStrict(dateStr);
      final now = DateTime.now();
      return parsed.year == now.year && parsed.month == now.month && parsed.day == now.day;
    } catch (_) { return false; }
  }

  static Future<double?> fetchStockChange(String stockCode) async {
    String prefix;
    if (stockCode.startsWith('6')) prefix = 'sh';
    else if (stockCode.startsWith('8') || stockCode.startsWith('4')) prefix = 'bj';
    else prefix = 'sz';
    final url = 'https://qt.gtimg.cn/q=$prefix$stockCode';
    try {
      final bytes = await _getBytes(url);
      final parts = <String>[];
      int start = 0;
      for (int i = 0; i < bytes.length; i++) {
        if (bytes[i] == 0x7E) {
          parts.add(utf8.decode(bytes.sublist(start, i), allowMalformed: true));
          start = i + 1;
        }
      }
      if (start < bytes.length) parts.add(utf8.decode(bytes.sublist(start), allowMalformed: true));
      for (int idx in [31, 32, 33]) {
        if (parts.length > idx) {
          String raw = parts[idx].trim().replaceAll('%', '');
          if (raw.isNotEmpty && raw != '--') {
            final val = double.tryParse(raw);
            if (val != null) return val;
          }
        }
      }
      return null;
    } catch (e) {
      throw Exception('$stockCode: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> fetchHoldings(String fundCode) async {
    final url = 'https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$fundCode&topline=10';
    try {
      final body = await _get(url);
      final contentMatch = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (contentMatch == null) return [];
      String content = contentMatch.group(1)!;
      content = content.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&');
      final reg = RegExp(
        r'''<tr.*?><td.*?>\d+</td><td.*?><a[^>]*>(\d{6})</a></td><td.*?><a[^>]*>([^<]+)</a></td>.*?<td[^>]*class=["']tor["']>([\d\.]+)%''',
        dotAll: true,
      );
      final matches = reg.allMatches(content);
      final holdings = <Map<String, dynamic>>[];
      for (final m in matches) {
        final code = m.group(1)!;
        final name = m.group(2)!.trim();
        final pct = double.tryParse(m.group(3)!) ?? 0.0;
        if (code.length == 6 && pct > 0) {
          holdings.add({'code': code, 'name': name, 'pct': pct});
        }
      }
      return holdings;
    } catch (e) {
      return [];
    }
  }

  static Future<Map<String, dynamic>> fetchBaseInfo(String fundCode) async {
    final url = 'https://fund.eastmoney.com/$fundCode.html';
    try {
      final html = await _get(url);
      final nameMatch = RegExp(r'<title>([^<]+?)\(\d{6}\)').firstMatch(html);
      final fundName = nameMatch?.group(1)?.trim() ?? '基金$fundCode';
      String? nav, navDate;
      final navMatch = RegExp(r'单位净值[^)]*?\((\d{4}-\d{2}-\d{2})\)[^0-9]*?(\d+\.\d+)').firstMatch(html);
      if (navMatch != null) {
        navDate = navMatch.group(1);
        nav = navMatch.group(2);
      } else {
        final navMatch2 = RegExp(r'单位净值[^)]*?\((\d+-\d+)\)[^0-9]*?(\d+\.\d+)').firstMatch(html);
        if (navMatch2 != null) {
          navDate = navMatch2.group(1);
          nav = navMatch2.group(2);
        }
      }
      double? actualChange;
      final changeMatch = RegExp(r'>([+-]?\d+\.?\d*)%<').firstMatch(html);
      if (changeMatch != null) actualChange = double.tryParse(changeMatch.group(1)!);
      return {'fundName': fundName, 'nav': nav, 'navDate': navDate, 'actualChange': actualChange};
    } catch (e) {
      return {'fundName': '基金$fundCode', 'nav': null, 'navDate': null, 'actualChange': null};
    }
  }

  static Future<FundData> query(String fundCode) async {
    String? globalError;
    final session = getSessionLabel();
    final now = DateTime.now();
    final nowStr = DateFormat('HH:mm').format(now);

    Map<String, dynamic> base;
    try {
      base = await fetchBaseInfo(fundCode);
    } catch (e) {
      globalError = '获取基本信息失败: $e';
      base = {'fundName': '基金$fundCode', 'nav': null, 'navDate': null, 'actualChange': null};
    }
    final fundName = base['fundName'];
    final nav = base['nav'] as String?;
    final navDate = base['navDate'] as String?;
    final actualChange = base['actualChange'] as double?;

    List<Map<String, dynamic>> holdingsRaw = [];
    try {
      holdingsRaw = await fetchHoldings(fundCode);
    } catch (e) {
      if (globalError == null) globalError = '获取持仓失败: $e';
    }

    List<StockHolding> holdings = [];
    double totalPct = 0;
    double weightedChange = 0;
    int successCount = 0;
    if (holdingsRaw.isNotEmpty) {
      for (var h in holdingsRaw) {
        final pct = h['pct'] as double;
        totalPct += pct;
        final code = h['code'];
        double? change;
        String? errMsg;
        try {
          change = await fetchStockChange(code);
          if (change == null) errMsg = '解析失败';
        } catch (e) {
          errMsg = e.toString();
        }
        if (change != null) {
          weightedChange += pct * change;
          successCount++;
        }
        holdings.add(StockHolding(name: h['name'], code: code, pct: pct, change: change, errorMsg: errMsg));
      }
    }
    double estimatedChange = (totalPct > 0 && successCount > 0) ? weightedChange / 100.0 : 0.0;
    estimatedChange = double.parse(estimatedChange.toStringAsFixed(2));

    final navIsToday = isSameDay(navDate);
    FundData fundData;
    if (session == '交易中' || session == '午休') {
      fundData = FundData(
        fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
        estimatedChange: estimatedChange,
        estimatedNav: nav != null ? double.parse(nav) * (1 + estimatedChange / 100) : null,
        actualChange: null, isFinal: false,
        holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: session,
        networkError: globalError,
      );
    } else if (session == '已收盘') {
      if (navIsToday && actualChange != null) {
        fundData = FundData(
          fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
          estimatedChange: actualChange, estimatedNav: null, actualChange: actualChange,
          isFinal: true, holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '已收盘（最终）',
          networkError: globalError,
        );
      } else {
        fundData = FundData(
          fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
          estimatedChange: estimatedChange,
          estimatedNav: nav != null ? double.parse(nav) * (1 + estimatedChange / 100) : null,
          actualChange: null, isFinal: false,
          holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '待公布净值',
          networkError: globalError,
        );
      }
    } else {
      final change = actualChange ?? 0.0;
      fundData = FundData(
        fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
        estimatedChange: change, estimatedNav: null, actualChange: actualChange,
        isFinal: true, holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: '上交易日',
        networkError: globalError,
      );
    }
    return fundData;
  }
}

// ---- 持久化 ----
class FundStore {
  static Future<List<SavedFund>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('funds');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => SavedFund.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static Future<void> save(List<SavedFund> funds) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(funds.map((f) => f.toJson()).toList());
    await prefs.setString('funds', raw);
  }
}

// ---- UI ----
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<SavedFund> _savedFunds = [];
  Map<String, FundData?> _results = {};
  Map<String, bool> _loading = {};
  Map<String, bool> _expanded = {};
  Timer? _autoRefreshTimer;
  bool _initialLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _startAutoRefresh();
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final funds = await FundStore.load();
    setState(() {
      _savedFunds = funds;
      _initialLoading = false;
    });
    if (funds.isNotEmpty) _refreshAll();
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (mounted && _savedFunds.isNotEmpty) _refreshAll();
    });
  }

  Future<void> _refreshAll() async {
    for (var f in _savedFunds) {
      _querySingle(f.code);
    }
  }

  Future<void> _querySingle(String code) async {
    if (_loading[code] == true) return;
    setState(() => _loading[code] = true);
    try {
      final result = await FundApi.query(code);
      setState(() {
        _results[code] = result;
        _loading[code] = false;
      });
    } catch (e) {
      setState(() {
        _results[code] = FundData(
          fundName: code, fundCode: code, estimatedChange: 0, isFinal: false,
          holdings: [], totalPct: 0, updateTime: '', status: '查询失败', networkError: e.toString(),
        );
        _loading[code] = false;
      });
    }
  }

  Future<void> _addFund(String code, double amount) async {
    if (_savedFunds.any((f) => f.code == code)) {
      // 已存在则更新金额
      final idx = _savedFunds.indexWhere((f) => f.code == code);
      _savedFunds[idx].amount = amount;
    } else {
      _savedFunds.add(SavedFund(code: code, amount: amount));
      _expanded[code] = false;
    }
    await FundStore.save(_savedFunds);
    setState(() {});
    _querySingle(code);
  }

  Future<void> _deleteFund(String code) async {
    _savedFunds.removeWhere((f) => f.code == code);
    _results.remove(code);
    _loading.remove(code);
    _expanded.remove(code);
    await FundStore.save(_savedFunds);
    setState(() {});
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空所有'),
        content: const Text('确定要清空所有基金吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (confirm == true) {
      _savedFunds.clear();
      _results.clear();
      _loading.clear();
      _expanded.clear();
      await FundStore.save(_savedFunds);
      setState(() {});
    }
  }

  void _showAddDialog() {
    final codeCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加基金'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeCtrl,
              decoration: const InputDecoration(labelText: '基金代码', border: OutlineInputBorder(), isDense: true),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              buildCounter: (_, {required int currentLength, required bool isFocused, int? maxLength}) => null,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              decoration: const InputDecoration(labelText: '持有金额（元，可选）', border: OutlineInputBorder(), isDense: true),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final code = codeCtrl.text.trim();
              if (code.length != 6) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('请输入6位基金代码')));
                return;
              }
              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
              Navigator.pop(ctx);
              _addFund(code, amount);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('基金净值预估'),
        centerTitle: false,
        actions: [
          if (_savedFunds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清空所有',
              onPressed: _clearAll,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '手动刷新',
            onPressed: _savedFunds.isNotEmpty ? _refreshAll : null,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        child: const Icon(Icons.add),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_savedFunds.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_balance, size: 64, color: kTextMuted),
            SizedBox(height: 16),
            Text('点击右下角 + 添加基金', style: TextStyle(color: kTextMuted, fontSize: 16)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _refreshAll(),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _savedFunds.length,
        itemBuilder: (ctx, i) => _buildFundCard(_savedFunds[i]),
      ),
    );
  }

  Widget _buildFundCard(SavedFund saved) {
    final code = saved.code;
    final data = _results[code];
    final isLoading = _loading[code] == true;
    final isExpanded = _expanded[code] ?? false;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (data == null && !isLoading) _querySingle(code);
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：基金名称 + 删除
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          data?.fundName ?? '查询中…',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(code, style: const TextStyle(fontSize: 12, color: kTextMuted)),
                      ],
                    ),
                  ),
                  if (isLoading)
                    const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  PopupMenuButton<String>(
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(color: kRedUp))),
                    ],
                    onSelected: (v) {
                      if (v == 'delete') _showDeleteConfirm(code);
                    },
                  ),
                ],
              ),

              // 净值 + 涨跌幅 + 预估收益
              if (data != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (data.nav != null)
                      Text('净值 ${data.nav!} (${data.navDate ?? "--"})', style: const TextStyle(fontSize: 12, color: kTextMuted)),
                    const Spacer(),
                    Text(data.status, style: const TextStyle(fontSize: 11, color: kTextMuted)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _changeWidget(data.estimatedChange, data.isFinal ? '' : '预估'),
                    if (data.estimatedNav != null) ...[
                      const SizedBox(width: 12),
                      Text('≈ ${data.estimatedNav!.toStringAsFixed(4)}', style: const TextStyle(fontSize: 12, color: kTextMuted)),
                    ],
                    const Spacer(),
                    // 预估收益
                    if (saved.amount > 0) ...[
                                           Text(
                        _earningsText(saved.amount, data.estimatedChange),
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _earningsColor2(saved.amount, data.estimatedChange)),
                      ),
                                      ],
                ),
                if (saved.amount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('持有 ${saved.amount.toStringAsFixed(0)} 元', style: const TextStyle(fontSize: 11, color: kTextMuted)),
                  ),

                const Divider(height: 20),

                // 持仓折叠按钮
                InkWell(
                  onTap: () => setState(() => _expanded[code] = !isExpanded),
                  child: Row(
                    children: [
                      Text(
                        '前十大持仓 (${data.totalPct.toStringAsFixed(1)}%)',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 20, color: kTextMuted),
                    ],
                  ),
                ),

                // 持仓列表（可折叠）
                if (isExpanded) ...[
                  const SizedBox(height: 8),
                  if (data.holdings.isEmpty)
                    const Text('暂无持仓数据', style: TextStyle(color: kTextMuted, fontSize: 13))
                  else
                    ...data.holdings.map((h) => _buildStockRow(h)),
                ],
              ],

              // 错误提示
              if (data?.networkError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('⚠ ${data!.networkError}', style: const TextStyle(fontSize: 11, color: Colors.orange)),
                ),

              // 更新时间
              if (data != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${data.updateTime}', style: const TextStyle(fontSize: 10, color: kTextMuted)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _changeWidget(double change, String label) {
    final color = change >= 0 ? kRedUp : kGreenDown;
    final sign = change >= 0 ? '+' : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(label, style: const TextStyle(fontSize: 11, color: kTextMuted)),
          ),
        Text(
          '$sign${change.toStringAsFixed(2)}%',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  Widget _buildStockRow(StockHolding s) {
    bool hasError = s.change == null;
    double changeVal = s.change ?? 0.0;
    final color = (!hasError && changeVal >= 0) ? kRedUp : kGreenDown;
    final sign = (!hasError && changeVal >= 0) ? '+' : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(s.name, style: const TextStyle(fontSize: 13))),
          Text('${s.pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12, color: kTextMuted)),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (hasError)
                  Tooltip(message: s.errorMsg ?? '失败', child: const Icon(Icons.error_outline, size: 14, color: Colors.orange))
                else
                  Text('$sign${changeVal.toStringAsFixed(2)}%',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }

    String _earningsText(double amount, double change) {
    final earnings = amount * change / 100;
    final sign = earnings >= 0 ? '+' : '';
    return '收益 ' + sign + earnings.toStringAsFixed(2);
  }
  Color _earningsColor2(double amount, double change) {
    final earnings = amount * change / 100;
    return earnings >= 0 ? kRedUp : kGreenDown;
  }
  void _showDeleteConfirm(String code) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除基金'),
        content: Text('确定删除基金 $code 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () { Navigator.pop(ctx); _deleteFund(code); }, child: const Text('确定', style: TextStyle(color: kRedUp))),
        ],
      ),
    );
  }
}
