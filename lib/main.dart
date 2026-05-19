import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF1F3F5),
      ),
      home: const HomePage(),
    );
  }
}

// ---------- 颜色 ----------
const Color kRedUp = Color(0xFFEF4444);
const Color kGreenDown = Color(0xFF10B981);
const Color kTextMuted = Color(0xFF64748B);
const Color kCardBg = Color(0xFFFFFFFF);
const Color kBorder = Color(0xFFE2E8F0);

// ---------- 数据模型 ----------
class StockHolding {
  final String name;
  final String code;
  final double pct;
  final double change;
  StockHolding({required this.name, required this.code, required this.pct, required this.change});
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
  FundData({
    required this.fundName, required this.fundCode,
    this.nav, this.navDate,
    required this.estimatedChange,
    this.estimatedNav, this.actualChange,
    required this.isFinal, required this.holdings,
    required this.totalPct, required this.updateTime,
    required this.status,
  });
}

// ---------- API ----------
class FundApi {
  static const _timeout = Duration(seconds: 15);

  /// 完整浏览器头 — 跟你之前说有持仓数据的那版一致
  static Map<String, String> _headers() => {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Referer': 'https://fund.eastmoney.com/',
    'Connection': 'keep-alive',
    'Accept-Encoding': 'gzip, deflate',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
  };

  /// 统一 GET 请求，优先原协议
  static Future<String> _get(String url) async {
    final headers = _headers();
    final uris = [url];
    if (url.startsWith('https://')) uris.add(url.replaceFirst('https://', 'http://'));
    else if (url.startsWith('http://')) uris.add(url.replaceFirst('http://', 'https://'));

    for (final u in uris) {
      try {
        final c = HttpClient()..connectionTimeout = _timeout..badCertificateCallback = (cert, host, port) => true;
        try {
          final rq = await c.getUrl(Uri.parse(u));
          headers.forEach((k, v) => rq.headers.set(k, v));
          final rp = await rq.close();
          if (rp.statusCode == 200) {
            return await rp.transform(utf8.decoder).join();
          }
        } finally { c.close(force: true); }
      } catch (_) {}
    }
    throw Exception('网络请求失败: $url');
  }

  // ----- 交易时段 -----
  static String getSessionLabel() {
    final now = DateTime.now();
    if (now.weekday > 5) return '休市';
    final t = now.hour * 60 + now.minute;
    if (t < 570) return '未开市';
    if (t <= 690) return '交易中';
    if (t < 780) return '午休';
    if (t <= 900) return '交易中';
    return '已收盘';
  }

  static bool _isSameDay(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return false;
    try {
      final p = dateStr.split('-');
      if (p.length < 3) return false;
      final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
      final now = DateTime.now();
      return d.year == now.year && d.month == now.month && d.day == now.day;
    } catch (_) { return false; }
  }

  // ----- 股票实时涨跌幅（腾讯）-----
  static Future<double> fetchStockChange(String stockCode) async {
    String prefix;
    if (stockCode.startsWith('6')) prefix = 'sh';
    else if (stockCode.startsWith('8') || stockCode.startsWith('4')) prefix = 'bj';
    else prefix = 'sz';
    try {
      final body = await _get('http://qt.gtimg.cn/q=$prefix$stockCode');
      final parts = body.split('~');
      if (parts.length > 31) {
        return double.tryParse(parts[31].trim()) ?? 0.0;
      }
    } catch (_) {}
    return 0.0;
  }

  // ----- 前十大持仓（天天基金 fundf10）-----
  static Future<List<Map<String, dynamic>>> fetchHoldings(String fundCode) async {
    try {
      final body = await _get('http://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$fundCode&topline=10');
      final cm = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (cm == null) return [];
      // 逐行解析 HTML 表格
      final html = cm.group(1)!;
      final results = <Map<String, dynamic>>[];
      // 匹配每一个 <tr>...</tr> 行
      final trPattern = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true);
      final trMatches = trPattern.allMatches(html);
      for (final tr in trMatches) {
        final trHtml = tr.group(1)!;
        // 跳过非数据行（比如表头）
        if (!trHtml.contains('class="tor"')) continue;
        // 提取股票代码 <a ...>600036</a>
        final codeMatch = RegExp(r'<a[^>]*>(\d{6})</a>').firstMatch(trHtml);
        if (codeMatch == null) continue;
        // 提取股票名称（第二个 <a>）
        final nameMatches = RegExp(r'<a[^>]*>([^<]+)</a>').allMatches(trHtml).toList();
        if (nameMatches.length < 2) continue;
        // 提取占比 <td class="tor">5.23%</td>
        final pctMatch = RegExp(r'class="tor"[^>]*>([\d\.]+)%').firstMatch(trHtml);
        if (pctMatch == null) continue;
        results.add({
          'code': codeMatch.group(1)!,
          'name': nameMatches[1].group(1)!.trim(),
          'pct': double.parse(pctMatch.group(1)!),
        });
      }
      return results;
    } catch (e) {
      print('获取持仓失败 $fundCode: $e');
      return [];
    }
  }

  // ----- 基金基本信息（天天基金页面）-----
  static Future<Map<String, dynamic>> fetchBaseInfo(String fundCode) async {
    try {
      final html = await _get('http://fund.eastmoney.com/$fundCode.html');
      final nameMatch = RegExp(r'<title>([^<]+?)\(\d{6}\)').firstMatch(html);
      final fundName = nameMatch?.group(1)?.trim() ?? '基金$fundCode';
      String? nav, navDate;
      final nm = RegExp(r'单位净值[^)]*?\((\d{4}-\d{2}-\d{2})\)[^0-9]*?(\d+\.\d+)').firstMatch(html);
      if (nm != null) { navDate = nm.group(1); nav = nm.group(2); }
      double? actualChange;
      final cm = RegExp(r'>([+-]?\d+\.?\d*)%<').firstMatch(html);
      if (cm != null) actualChange = double.tryParse(cm.group(1)!);
      return {'fundName': fundName, 'nav': nav, 'navDate': navDate, 'actualChange': actualChange};
    } catch (e) {
      print('获取基本信息失败 $fundCode: $e');
      return {'fundName': '基金$fundCode', 'nav': null, 'navDate': null, 'actualChange': null};
    }
  }

  // ----- 主查询 -----
  static Future<FundData> query(String fundCode) async {
    final session = getSessionLabel();
    final now = DateTime.now();
    final nowStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final base = await fetchBaseInfo(fundCode);
    final fundName = base['fundName'];
    final nav = base['nav'] as String?;
    final navDate = base['navDate'] as String?;
    final actualChange = base['actualChange'] as double?;

    // 持仓 + 加权计算涨跌幅
    final raw = await fetchHoldings(fundCode);
    final holdings = <StockHolding>[];
    double totalPct = 0;
    double weightedChange = 0;

    if (raw.isNotEmpty) {
      final changes = await Future.wait(raw.map((h) => fetchStockChange(h['code'])));
      for (int i = 0; i < raw.length; i++) {
        final pct = raw[i]['pct'] as double;
        final change = changes[i];
        totalPct += pct;
        weightedChange += pct * change;
        holdings.add(StockHolding(name: raw[i]['name'], code: raw[i]['code'], pct: pct, change: change));
      }
    }

    double estimatedChange = totalPct > 0 ? weightedChange / 100.0 : 0.0;
    estimatedChange = double.parse(estimatedChange.toStringAsFixed(2));
    double? estimatedNav;
    if (nav != null) {
      estimatedNav = double.parse(nav) * (1 + estimatedChange / 100);
      estimatedNav = double.parse(estimatedNav.toStringAsFixed(4));
    }

    final navIsToday = _isSameDay(navDate);

    if (session == '交易中' || session == '午休') {
      return FundData(
        fundName: fundName, fundCode: fundCode,
        nav: nav, navDate: navDate,
        estimatedChange: estimatedChange, estimatedNav: estimatedNav,
        actualChange: null, isFinal: false,
        holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: session,
      );
    } else if (session == '已收盘') {
      if (navIsToday && actualChange != null) {
        return FundData(
          fundName: fundName, fundCode: fundCode,
          nav: nav, navDate: navDate,
          estimatedChange: actualChange, estimatedNav: null,
          actualChange: actualChange, isFinal: true,
          holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '已收盘（最终）',
        );
      } else {
        return FundData(
          fundName: fundName, fundCode: fundCode,
          nav: nav, navDate: navDate,
          estimatedChange: estimatedChange, estimatedNav: estimatedNav,
          actualChange: null, isFinal: false,
          holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '待公布净值',
        );
      }
    } else { // 未开市/休市
      final change = actualChange ?? 0.0;
      final finalStatus = actualChange != null ? '上交易日' : session;
      return FundData(
        fundName: fundName, fundCode: fundCode,
        nav: nav, navDate: navDate,
        estimatedChange: change, estimatedNav: null,
        actualChange: actualChange, isFinal: true,
        holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: finalStatus,
      );
    }
  }
}

// ---------- 页面 ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _ctrl = TextEditingController();
  FundData? _data;
  bool _loading = false;
  String? _error;

  Future<void> _query() async {
    final code = _ctrl.text.trim();
    if (code.length != 6 || !RegExp(r'^\d{6}$').hasMatch(code)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入6位基金代码')));
      return;
    }
    setState(() { _loading = true; _error = null; _data = null; });
    try {
      final result = await FundApi.query(code);
      setState(() { _data = result; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('基金净值预估'), centerTitle: false),
      body: Column(children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                decoration: const InputDecoration(labelText: '基金代码', border: OutlineInputBorder(), isDense: true),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 6,
                buildCounter: (_, {required int currentLength, required bool isFocused, int? maxLength}) => null,
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(onPressed: _loading ? null : _query, child: const Text('查询')),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text('❌ $_error', style: const TextStyle(color: kRedUp)))
                  : _data == null
                      ? const Center(child: Text('输入基金代码查询'))
                      : _buildResult(_data!),
        ),
      ]),
    );
  }

  Widget _buildResult(FundData d) {
    final change = d.estimatedChange;
    final changeColor = change >= 0 ? kRedUp : kGreenDown;
    final changeSign = change >= 0 ? '+' : '';
    final changeText = '$changeSign${change.toStringAsFixed(2)}%';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${d.fundName} (${d.fundCode})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (d.nav != null) Text('单位净值: ${d.nav} (${d.navDate ?? "--"})', style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 4),
        Text('涨跌幅: $changeText', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: changeColor)),
        if (d.estimatedNav != null) Text('预估净值: ${d.estimatedNav!.toStringAsFixed(4)}', style: const TextStyle(fontSize: 12, color: kTextMuted)),
        Text('状态: ${d.status}', style: const TextStyle(fontSize: 12, color: kTextMuted)),
        const Divider(height: 24),

        // 持仓
        Text('前十大持仓 (合计 ${d.totalPct.toStringAsFixed(1)}%)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (d.holdings.isEmpty)
          const Text('暂无持仓数据', style: TextStyle(color: kTextMuted))
        else
          Column(children: d.holdings.map(_buildStockRow).toList()),
        const SizedBox(height: 8),
        Text('更新时间: ${d.updateTime}', style: const TextStyle(fontSize: 10, color: kTextMuted, fontStyle: FontStyle.italic)),
      ]),
    );
  }

  Widget _buildStockRow(StockHolding s) {
    final changeColor = s.change >= 0 ? kRedUp : kGreenDown;
    final sign = s.change >= 0 ? '+' : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(color: kCardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: kBorder)),
      child: Row(children: [
        Expanded(flex: 3, child: Text(s.name, style: const TextStyle(fontSize: 14))),
        SizedBox(width: 50, child: Text('${s.pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 13, color: kTextMuted), textAlign: TextAlign.right)),
        const SizedBox(width: 8),
        SizedBox(width: 70, child: Text('$sign${s.change.toStringAsFixed(2)}%', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: changeColor), textAlign: TextAlign.right)),
      ]),
    );
  }
}
