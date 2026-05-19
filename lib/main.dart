import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const FundApp());
}

class FundApp extends StatelessWidget {
  const FundApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '基金查询',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4361EE),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF1F3F5),
      ),
      home: const QueryPage(),
    );
  }
}

// ─── 颜色 ───
const Color kRedUp = Color(0xFFEF4444);
const Color kGreenDown = Color(0xFF10B981);
const Color kMuted = Color(0xFF64748B);

// ─── 数据模型 ───
class StockHolding {
  final String name;
  final String code;
  final double pct;
  final double change; // 涨跌幅 %
  StockHolding({required this.name, required this.code, required this.pct, required this.change});
}

class FundResult {
  final String name;
  final String code;
  final String? nav;        // 最新净值
  final String? navDate;    // 净值日期
  final double? actualChange; // 实际涨跌幅（如已公布）
  final bool hasFinalNav;   // 今日净值是否已公布
  final List<StockHolding> holdings;
  final double totalPct;    // 持仓合计
  final String updateTime;  // 更新时间
  final String statusStr;   // 状态文字

  FundResult({
    required this.name,
    required this.code,
    this.nav,
    this.navDate,
    this.actualChange,
    required this.hasFinalNav,
    required this.holdings,
    required this.totalPct,
    required this.updateTime,
    required this.statusStr,
  });
}

// ─── API ───
class FundApi {
  static const _timeout = Duration(seconds: 15);
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';

  static Future<String> _get(String url, {Map<String, String>? headers}) async {
    headers ??= {'User-Agent': _ua, 'Accept': '*/*'};

    // 尝试两次：dart:io HttpClient
    for (var scheme in ['https', 'http']) {
      final u = url.replaceFirst(RegExp(r'^https?://'), '$scheme://');
      try {
        final uri = Uri.parse(u);
        final c = HttpClient()..connectionTimeout = _timeout..badCertificateCallback = (cert, host, port) => true;
        try {
          final r = await c.getUrl(uri);
          headers!.forEach((k, v) => r.headers.set(k, v));
          final resp = await r.close();
          if (resp.statusCode == 200) {
            final body = await resp.transform(utf8.decoder).join();
            return body;
          }
        } finally { c.close(force: true); }
      } catch (_) {}
    }

    // 兜底：改用 Dart socket 直接发 HTTP 请求
    throw Exception('网络请求失败: $url');
  }

  /// 获取交易时段
  static String _sessionLabel() {
    final now = DateTime.now();
    if (now.weekday > 5) return '休市';
    final t = now.hour * 60 + now.minute;
    if (t < 570) return '未开市';   // 9:30
    if (t <= 690) return '交易中';  // 11:30
    if (t < 780) return '午休';     // 13:00
    if (t <= 900) return '交易中';  // 15:00
    return '已收盘';
  }

/// 获取股票涨跌幅（腾讯行情）
  static Future<double> _stockChange(String code) async {
    String prefix;
    if (code.startsWith('6')) prefix = 'sh';
    else if (code.startsWith('8') || code.startsWith('4')) prefix = 'bj';
    else prefix = 'sz';

    // 腾讯行情
    try {
      final body = await _get('http://qt.gtimg.cn/q=$prefix$code');
      final parts = body.split('~');
      if (parts.length > 32) {
        final v = double.tryParse(parts[32].trim());
        if (v != null) return v;
      }
    } catch (_) {}

    // 新浪行情兜底
    try {
      final body = await _get('http://hq.sinajs.cn/list=$prefix$code');
      final parts = body.split(',');
      // 新浪格式: var hq_str_sh600000="名称,开盘,昨收,当前,最高,最低,...涨跌幅,..."
      if (parts.length > 30) {
        final v = double.tryParse(parts[30].trim());
        if (v != null) return v;
      }
    } catch (_) {}

    return 0.0;
  }

  /// 获取持仓（新浪财经接口）
  static Future<List<Map<String, dynamic>>> _holdings(String code) async {
    // 新浪基金持仓接口
    final url = 'http://vip.stock.finance.sina.com.cn/fund_center/api/jsonp.php/IO.XSRV2.FundJJDX/FundJJDX_GetJJDX?c=$code';
    try {
      final body = await _get(url);
      if (body.isEmpty || body == 'null') return [];
      // 新浪返回格式: IO.XSRV2.FundJJDX([{...},{...}])
      // 也可能是纯 JSON
      String jsonStr = body.trim();
      // 去掉函数包裹
      final m = RegExp(r'^\w+\((.+)\)$', dotAll: true).firstMatch(jsonStr);
      if (m != null) jsonStr = m.group(1)!;
      jsonStr = jsonStr.trim();
      if (jsonStr.startsWith('[') || jsonStr.startsWith('{')) {
        final list = jsonDecode(jsonStr) as List;
        return list.map((item) {
          final Map<String, dynamic> map = item is Map ? item as Map<String, dynamic> : {};
          final stockCode = (map['symbol'] as String? ?? '').replaceAll(RegExp(r'^(sh|sz|bj)'), '');
          return <String, dynamic>{
            'code': stockCode,
            'name': map['name'] as String? ?? map['stock_name'] as String? ?? '',
            'pct': (map['jjzbl'] as num?)?.toDouble() ?? (map['hold_ratio'] as num?)?.toDouble() ?? 0,
          };
        }).toList();
      }
    } catch (_) {}

    // fallback: 用 fundf10 接口试试
    try {
      final body = await _get('http://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$code&topline=10');
      final m = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (m == null) return [];
      final rows = RegExp(
        '''<tr.*?><td.*?>\d+</td><td.*?><a[^>]*>(\d{6})</a></td><td.*?><a[^>]*>([^<]+)</a></td>.*?<td[^>]*class=["']tor["']>([\d\.]+)%''',
        dotAll: true,
      ).allMatches(m.group(1)!);
      return rows.map((r) => <String, dynamic>{
        'code': r.group(1)!, 'name': r.group(2)!.trim(), 'pct': double.tryParse(r.group(3)!) ?? 0,
      }).toList();
    } catch (_) { return []; }
  }

  /// 获取基本信息（fundgz HTTP 接口）
  static Future<Map<String, dynamic>> _baseInfo(String code) async {
    String name = '基金$code';
    String? nav, navDate;
    double? actualChange;
    try {
      final body = await _get('http://fundgz.1234567.com.cn/js/$code.js');
      final m = RegExp(r'jsonpgz\((.+)\)').firstMatch(body);
      if (m != null) {
        final j = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        name = j['name'] as String? ?? name;
        nav = j['dwjz'] as String?;
        navDate = j['jzrq'] as String?;
      }
    } catch (_) {}
    return {'name': name, 'nav': nav, 'navDate': navDate, 'actualChange': actualChange};
  }

  /// 查询基金
  static Future<FundResult> query(String code) async {
    final base = await _baseInfo(code);
    final name = base['name'];
    final nav = base['nav'] as String?;
    final navDate = base['navDate'] as String?;
    final actualChange = base['actualChange'] as double?;

    final holdings = await _holdings(code);
    final stocks = <StockHolding>[];
    double totalPct = 0;

    if (holdings.isNotEmpty) {
      final changes = await Future.wait(holdings.map((h) => _stockChange(h['code'] as String)));
      for (int i = 0; i < holdings.length; i++) {
        final h = holdings[i];
        final pct = h['pct'] as double;
        totalPct += pct;
        stocks.add(StockHolding(name: h['name'], code: h['code'], pct: pct, change: changes[i]));
      }
    }

    final now = DateTime.now();
    final session = _sessionLabel();
    final nowStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // 判断今日净值是否已公布
    bool hasFinal = false;
    if (navDate != null && actualChange != null) {
      try {
        final d = DateTime.tryParse(navDate);
        if (d != null && d.year == now.year && d.month == now.month && d.day == now.day) {
          hasFinal = true;
        }
      } catch (_) {}
    }

    String status;
    if (session == '休市' || session == '未开市') {
      status = hasFinal ? '已收盘' : '非交易时间';
    } else if (session == '交易中' || session == '午休') {
      status = '实时估算';
    } else {
      status = hasFinal ? '已收盘' : '待公布净值';
    }

    return FundResult(
      name: name, code: code, nav: nav, navDate: navDate,
      actualChange: actualChange, hasFinalNav: hasFinal,
      holdings: stocks, totalPct: totalPct,
      updateTime: nowStr, statusStr: status,
    );
  }
}

// ─── 页面 ───
class QueryPage extends StatefulWidget {
  const QueryPage({super.key});
  @override
  State<QueryPage> createState() => _QueryPageState();
}

class _QueryPageState extends State<QueryPage> {
  final _codeCtrl = TextEditingController();
  FundResult? _result;
  bool _loading = false;
  String? _error;

  Future<void> _query() async {
    final code = _codeCtrl.text.trim();
    if (code.length != 6 || !RegExp(r'^\d{6}$').hasMatch(code)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入6位数字基金代码')),
      );
      return;
    }
    setState(() { _loading = true; _error = null; _result = null; });
    try {
      final r = await FundApi.query(code);
      setState(() { _result = r; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  void dispose() { _codeCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('基金查询'), centerTitle: false),
      body: Column(children: [
        // 输入区
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            SizedBox(
              width: 160,
              child: TextField(
                controller: _codeCtrl,
                decoration: const InputDecoration(
                  labelText: '基金代码', border: OutlineInputBorder(),
                  isDense: true, hintText: '6位数字',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 6,
                buildCounter: (_, {required int currentLength, required bool isFocused, int? maxLength}) => null,
                onSubmitted: (_) => _query(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _loading ? null : _query, child: const Text('查询')),
          ]),
        ),
        const Divider(height: 1),

        // 结果区
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text('❌ $_error', style: const TextStyle(color: kRedUp)))
                  : _result == null
                      ? const Center(child: Text('输入基金代码查询', style: TextStyle(color: kMuted, fontSize: 16)))
                      : _buildResult(_result!),
        ),
      ]),
    );
  }

  Widget _buildResult(FundResult r) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 基金名称 + 状态
        _section('基金信息', [
          _row('名称', r.name),
          _row('代码', r.code),
          _row('状态', r.statusStr),
          _row('更新时间', r.updateTime),
        ]),

        const SizedBox(height: 12),

        // 净值信息
        if (r.nav != null) _section('最新净值', [
          _row('单位净值', r.nav!),
          if (r.navDate != null) _row('净值日期', r.navDate!),
        ]),
        if (r.actualChange != null && r.hasFinalNav)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text('今日涨跌: ${r.actualChange! >= 0 ? "+" : ""}${r.actualChange!.toStringAsFixed(2)}%',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                color: r.actualChange! >= 0 ? kRedUp : kGreenDown)),
          ),

        const SizedBox(height: 12),

        // 持仓
        if (r.holdings.isNotEmpty) ...[
          _section('持仓股票 (${r.holdings.length}只)', [
            _row('持仓合计', '${r.totalPct.toStringAsFixed(1)}%'),
          ]),
          const SizedBox(height: 4),
          ...r.holdings.map((s) => _stockTile(s)),
        ] else
          _section('持仓股票', [_row('提示', '未获取到持仓数据')]),
      ]),
    );
  }

  Widget _section(String title, List<Widget> rows) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ...rows,
      ]),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(color: kMuted, fontSize: 14))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 14))),
      ]),
    );
  }

  Widget _stockTile(StockHolding s) {
    final color = s.change >= 0 ? kRedUp : kGreenDown;
    final sign = s.change >= 0 ? '+' : '';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(children: [
        Expanded(child: Text(s.name, style: const TextStyle(fontSize: 14))),
        const SizedBox(width: 8),
        Text('${s.pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 13, color: kMuted)),
        const SizedBox(width: 12),
        SizedBox(
          width: 70,
          child: Text('$sign${s.change.toStringAsFixed(2)}%',
            style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.bold),
            textAlign: TextAlign.right),
        ),
      ]),
    );
  }
}
