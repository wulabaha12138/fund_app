import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;

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

const Color kRedUp = Color(0xFFEF4444);
const Color kGreenDown = Color(0xFF10B981);
const Color kTextMuted = Color(0xFF64748B);
const Color kCardBg = Color(0xFFFFFFFF);
const Color kBorder = Color(0xFFE2E8F0);

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
  });
}

class FundApi {
  static const _timeout = Duration(seconds: 15);
  static const _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';

  static Future<String> _get(String url, {Map<String, String>? headers}) async {
    headers ??= {
      'User-Agent': _userAgent,
      'Referer': 'https://fund.eastmoney.com/',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    };
    for (var scheme in ['https', 'http']) {
      final fixedUrl = url.replaceFirst(RegExp(r'^https?://'), '$scheme://');
      final uri = Uri.parse(fixedUrl);
      final client = HttpClient()
        ..connectionTimeout = _timeout
        ..badCertificateCallback = (cert, host, port) => true;
      try {
        final request = await client.getUrl(uri);
        headers.forEach((k, v) => request.headers.set(k, v));
        final response = await request.close();
        if (response.statusCode == 200) {
          return await response.transform(utf8.decoder).join();
        }
      } catch (e) {
        print('请求失败 $scheme://: $e');
      } finally {
        client.close();
      }
    }
    throw Exception('网络请求失败: $url');
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
      final parts = dateStr.split('-');
      if (parts.length < 3) return false;
      final parsed = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      final now = DateTime.now();
      return parsed.year == now.year && parsed.month == now.month && parsed.day == now.day;
    } catch (_) { return false; }
  }

  // 腾讯个股涨跌幅
  static Future<double> fetchStockChange(String stockCode) async {
    String prefix;
    if (stockCode.startsWith('6')) prefix = 'sh';
    else if (stockCode.startsWith('8') || stockCode.startsWith('4')) prefix = 'bj';
    else prefix = 'sz';
    final url = 'https://qt.gtimg.cn/q=$prefix$stockCode';
    try {
      final body = await _get(url);
      final parts = body.split('~');
      if (parts.length > 31) {
        final changeStr = parts[31].trim();
        return double.tryParse(changeStr) ?? 0.0;
      }
    } catch (e) {
      print('获取股票 $stockCode 涨跌幅失败: $e');
    }
    return 0.0;
  }

  // 天天基金持仓（正则 + html fallback）
  static Future<List<Map<String, dynamic>>> fetchHoldings(String fundCode) async {
    final url = 'https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$fundCode&topline=10';
    try {
      final body = await _get(url);
      final contentMatch = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (contentMatch == null) {
        print('未找到 content 字段');
        return [];
      }
      String content = contentMatch.group(1)!;
      // 解码 HTML 实体
      content = content.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&');

      // 方法1：正则（与 Python 版相同）
      // 使用三引号字符串避免 Dart raw 字符串中 \' 的转义问题
      const pattern = '''<tr.*?><td.*?>\\d+</td><td.*?><a[^>]*>(\\d{6})</a></td><td.*?><a[^>]*>([^<]+)</a></td>.*?<td[^>]*class=["']tor["']>([\\d\\.]+)%''';
      final reg = RegExp(pattern, dotAll: true);
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
      if (holdings.isNotEmpty) {
        print('正则解析到 ${holdings.length} 条持仓');
        return holdings;
      }

      // 方法2：html 包 fallback
      final document = html_parser.parse(content);
      final rows = document.querySelectorAll('table tr');
      for (var row in rows) {
        final cells = row.querySelectorAll('td');
        if (cells.length >= 4) {
          final codeLink = cells[1].querySelector('a');
          final nameLink = cells[2].querySelector('a');
          final pctCell = cells[3];
          if (codeLink != null && nameLink != null && pctCell != null) {
            String code = codeLink.text.trim();
            String name = nameLink.text.trim();
            String pctStr = pctCell.text.trim().replaceAll('%', '');
            double pct = double.tryParse(pctStr) ?? 0.0;
            if (code.length == 6 && pct > 0) {
              holdings.add({'code': code, 'name': name, 'pct': pct});
            }
          }
        }
      }
      print('DOM 解析到 ${holdings.length} 条持仓');
      return holdings;
    } catch (e) {
      print('持仓解析异常: $e');
      return [];
    }
  }

  // 天天基金基本信息（名称、净值、实际涨跌幅）
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
      print('基本信息失败: $e');
      return {'fundName': '基金$fundCode', 'nav': null, 'navDate': null, 'actualChange': null};
    }
  }

  static Future<FundData> query(String fundCode) async {
    final session = getSessionLabel();
    final now = DateTime.now();
    final nowStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final base = await fetchBaseInfo(fundCode);
    final fundName = base['fundName'];
    final nav = base['nav'] as String?;
    final navDate = base['navDate'] as String?;
    final actualChange = base['actualChange'] as double?;

    final holdingsRaw = await fetchHoldings(fundCode);
    List<StockHolding> holdings = [];
    double totalPct = 0;
    double weightedChange = 0;
    if (holdingsRaw.isNotEmpty) {
      final changes = await Future.wait(holdingsRaw.map((h) => fetchStockChange(h['code'])));
      for (int i = 0; i < holdingsRaw.length; i++) {
        final h = holdingsRaw[i];
        final pct = h['pct'] as double;
        final change = changes[i];
        totalPct += pct;
        weightedChange += pct * change;
        holdings.add(StockHolding(name: h['name'], code: h['code'], pct: pct, change: change));
      }
    }
    double estimatedChange = totalPct > 0 ? weightedChange / 100.0 : 0.0;
    estimatedChange = double.parse(estimatedChange.toStringAsFixed(2));

    final navIsToday = isSameDay(navDate);
    if (session == '交易中' || session == '午休') {
      return FundData(
        fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
        estimatedChange: estimatedChange,
        estimatedNav: nav != null ? double.parse(nav) * (1 + estimatedChange / 100) : null,
        actualChange: null, isFinal: false,
        holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: session,
      );
    } else if (session == '已收盘') {
      if (navIsToday && actualChange != null) {
        return FundData(
          fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
          estimatedChange: actualChange, estimatedNav: null, actualChange: actualChange,
          isFinal: true, holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '已收盘（最终）',
        );
      } else {
        return FundData(
          fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
          estimatedChange: estimatedChange,
          estimatedNav: nav != null ? double.parse(nav) * (1 + estimatedChange / 100) : null,
          actualChange: null, isFinal: false,
          holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '待公布净值',
        );
      }
    } else {
      final change = actualChange ?? 0.0;
      final finalStatus = actualChange != null ? '上交易日' : session;
      return FundData(
        fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
        estimatedChange: change, estimatedNav: null, actualChange: actualChange,
        isFinal: true, holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: finalStatus,
      );
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _codeController = TextEditingController();
  FundData? _data;
  bool _loading = false;
  String? _error;

  Future<void> _query() async {
    final code = _codeController.text.trim();
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
                controller: _codeController,
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
    final color = change >= 0 ? kRedUp : kGreenDown;
    final sign = change >= 0 ? '+' : '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${d.fundName} (${d.fundCode})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (d.nav != null) Text('单位净值: ${d.nav} (${d.navDate ?? "--"})', style: const TextStyle(fontSize: 14)),
        Text('涨跌幅: $sign${change.toStringAsFixed(2)}%', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        if (d.estimatedNav != null) Text('预估净值: ${d.estimatedNav!.toStringAsFixed(4)}', style: const TextStyle(fontSize: 12, color: kTextMuted)),
        Text('状态: ${d.status}', style: const TextStyle(fontSize: 12, color: kTextMuted)),
        const Divider(height: 24),
        Text('前十大持仓 (合计 ${d.totalPct.toStringAsFixed(1)}%)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (d.holdings.isEmpty)
          const Text('暂无持仓数据', style: TextStyle(color: kTextMuted))
        else
          Column(children: d.holdings.map((h) => _buildStockRow(h)).toList()),
        const SizedBox(height: 8),
        Text('更新时间: ${d.updateTime}', style: const TextStyle(fontSize: 10, color: kTextMuted)),
      ]),
    );
  }

  Widget _buildStockRow(StockHolding s) {
    final color = s.change >= 0 ? kRedUp : kGreenDown;
    final sign = s.change >= 0 ? '+' : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(color: kCardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: kBorder)),
      child: Row(children: [
        Expanded(flex: 3, child: Text(s.name, style: const TextStyle(fontSize: 14))),
        SizedBox(width: 50, child: Text('${s.pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 13, color: kTextMuted), textAlign: TextAlign.right)),
        const SizedBox(width: 8),
        SizedBox(width: 70, child: Text('$sign${s.change.toStringAsFixed(2)}%', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color), textAlign: TextAlign.right)),
      ]),
    );
  }
}
