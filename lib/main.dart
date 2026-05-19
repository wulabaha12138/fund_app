import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:intl/intl.dart';

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
  final double? change; // 允许为 null，表示获取失败
  final String? errorMsg; // 错误信息
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
  final String? networkError; // 全局网络错误
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
        // 继续尝试下一个协议
      } finally {
        client.close();
      }
    }
    throw Exception('网络请求失败，请检查网络或稍后重试');
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

  // 个股涨跌幅（完全对齐 Python 版）
  static Future<double?> fetchStockChange(String stockCode) async {
    String prefix;
    if (stockCode.startsWith('6')) prefix = 'sh';
    else if (stockCode.startsWith('8') || stockCode.startsWith('4')) prefix = 'bj';
    else prefix = 'sz';
    final url = 'https://qt.gtimg.cn/q=$prefix$stockCode';
    try {
      final body = await _get(url);
      final parts = body.split('~');
      // 与 Python 版完全一致：优先取索引 32，再取索引 31
      if (parts.length > 32) {
        final raw = parts[32].trim().replaceAll('%', '');
        if (raw.isNotEmpty && raw != '--') {
          final val = double.tryParse(raw);
          if (val != null) return val;
        }
      }
      if (parts.length > 31) {
        final raw = parts[31].trim().replaceAll('%', '');
        if (raw.isNotEmpty && raw != '--') {
          final val = double.tryParse(raw);
          if (val != null) return val;
        }
      }
      return null; // 解析失败
    } catch (e) {
      return null; // 网络异常
    }
  }

  // 天天基金持仓（使用正则）
  static Future<List<Map<String, dynamic>>> fetchHoldings(String fundCode) async {
    final url = 'https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$fundCode&topline=10';
    try {
      final body = await _get(url);
      final contentMatch = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (contentMatch == null) return [];
      String content = contentMatch.group(1)!;
      // 解码常见 HTML 实体
      content = content.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&');
      // 与 Python 版完全一致的正则
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
          if (change == null) errMsg = '获取失败';
        } catch (e) {
          errMsg = e.toString();
        }
        if (change != null) {
          weightedChange += pct * change;
          successCount++;
        }
        holdings.add(StockHolding(
          name: h['name'],
          code: code,
          pct: pct,
          change: change,
          errorMsg: errMsg,
        ));
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
      final finalStatus = actualChange != null ? '上交易日' : session;
      fundData = FundData(
        fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
        estimatedChange: change, estimatedNav: null, actualChange: actualChange,
        isFinal: true, holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: finalStatus,
        networkError: globalError,
      );
    }
    return fundData;
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
        if (d.networkError != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(8),
            color: Colors.red.shade100,
            child: Text('⚠️ 网络异常: ${d.networkError}', style: const TextStyle(color: Colors.red)),
          ),
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
    // 如果涨跌幅为 null 或获取失败，显示 "--" 和错误图标
    bool hasError = s.change == null;
    double changeVal = s.change ?? 0.0;
    final color = (!hasError && changeVal >= 0) ? kRedUp : kGreenDown;
    final sign = (!hasError && changeVal >= 0) ? '+' : '';
    final displayText = hasError ? '--' : '$sign${changeVal.toStringAsFixed(2)}%';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(color: kCardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: kBorder)),
      child: Row(children: [
        Expanded(flex: 3, child: Text(s.name, style: const TextStyle(fontSize: 14))),
        SizedBox(width: 50, child: Text('${s.pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 13, color: kTextMuted), textAlign: TextAlign.right)),
        const SizedBox(width: 8),
        SizedBox(
          width: 70,
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (hasError)
              Icon(Icons.error_outline, size: 14, color: Colors.orange)
            else
              Text(displayText, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
      ]),
    );
  }
}

