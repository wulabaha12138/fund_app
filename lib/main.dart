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
  final double change;
  StockHolding({required this.name, required this.code, required this.pct, required this.change});
}

class FundResult {
  final String name;
  final String code;
  final String? nav;
  final String? navDate;
  final double? actualChange;
  final bool hasFinalNav;
  final List<StockHolding> holdings;
  final double totalPct;
  final String updateTime;
  final String statusStr;

  FundResult({
    required this.name, required this.code,
    this.nav, this.navDate, this.actualChange,
    required this.hasFinalNav, required this.holdings, required this.totalPct,
    required this.updateTime, required this.statusStr,
  });
}

// ─── API ───
class FundApi {
  static const _timeout = Duration(seconds: 15);
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';

  static Future<String> _get(String url, {Map<String, String>? headers}) async {
    headers ??= {'User-Agent': _ua, 'Accept': '*/*'};

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
            if (body.isNotEmpty) return body;
          }
        } finally { c.close(force: true); }
      } catch (_) {}
    }
    throw Exception('网络请求失败');
  }

  static String _sessionLabel() {
    final now = DateTime.now();
    if (now.weekday > 5) return '休市';
    final t = now.hour * 60 + now.minute;
    if (t < 570) return '未开市';
    if (t <= 690) return '交易中';
    if (t < 780) return '午休';
    if (t <= 900) return '交易中';
    return '已收盘';
  }

  /// B站热门视频（验证网络）
  static Future<List<String>> _bilibiliHot() async {
    try {
      final body = await _get('https://api.bilibili.com/x/web-interface/popular');
      final j = jsonDecode(body);
      final list = j['data']['list'] as List;
      return list.take(10).map((item) {
        final title = item['title'] as String? ?? '无标题';
        final bvid = item['bvid'] as String? ?? '';
        return '$title (https://www.bilibili.com/video/$bvid)';
      }).toList();
    } catch (e) {
      return ['❌ B站API请求失败: $e'];
    }
  }

  /// 腾讯行情
  static Future<double> _stockChange(String code) async {
    String prefix;
    if (code.startsWith('6')) prefix = 'sh';
    else if (code.startsWith('8') || code.startsWith('4')) prefix = 'bj';
    else prefix = 'sz';
    try {
      final body = await _get('http://qt.gtimg.cn/q=$prefix$code');
      final parts = body.split('~');
      if (parts.length > 32) {
        final v = double.tryParse(parts[32].trim());
        if (v != null) return v;
      }
    } catch (_) {}
    try {
      final body = await _get('http://hq.sinajs.cn/list=$prefix$code');
      final parts = body.split(',');
      if (parts.length > 30) {
        final v = double.tryParse(parts[30].trim());
        if (v != null) return v;
      }
    } catch (_) {}
    return 0.0;
  }

  /// 持仓（新浪）
  static Future<List<Map<String, dynamic>>> _holdings(String code) async {
    final url = 'http://vip.stock.finance.sina.com.cn/fund_center/api/jsonp.php/IO.XSRV2.FundJJDX/FundJJDX_GetJJDX?c=$code';
    try {
      final body = await _get(url);
      if (body.isEmpty || body == 'null') return [];
      String jsonStr = body.trim();
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
    return [];
  }

  /// 基本信息（fundgz）
  static Future<Map<String, dynamic>> _baseInfo(String code) async {
    try {
      final body = await _get('http://fundgz.1234567.com.cn/js/$code.js');
      final m = RegExp(r'jsonpgz\((.+)\)').firstMatch(body);
      if (m != null) {
        final j = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        return {
          'name': j['name'] ?? '基金$code',
          'nav': j['dwjz'],
          'navDate': j['jzrq'],
          'actualChange': null,
        };
      }
    } catch (_) {}
    return {'name': '基金$code', 'nav': null, 'navDate': null, 'actualChange': null};
  }

  /// 查询B站热门
  static Future<List<String>> bilibiliHot() => _bilibiliHot();

  /// 查询基金
  static Future<FundResult> query(String code) async {
    final base = await _baseInfo(code);
    final name = base['name'];
    final nav = base['nav'] as String?;
    final navDate = base['navDate'] as String?;

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

    bool hasFinal = false;
    if (navDate != null) {
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
      actualChange: null, hasFinalNav: hasFinal,
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
  List<String>? _bilibiliResult;
  bool _bilibiliLoading = false;

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

  Future<void> _queryBilibili() async {
    setState(() { _bilibiliLoading = true; _bilibiliResult = null; });
    try {
      final r = await FundApi.bilibiliHot();
      setState(() { _bilibiliResult = r; _bilibiliLoading = false; });
    } catch (e) {
      setState(() { _bilibiliResult = ['❌ 请求失败: $e']; _bilibiliLoading = false; });
    }
  }

  @override
  void dispose() { _codeCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('基金查询'),
        centerTitle: false,
        actions: [
          TextButton.icon(
            onPressed: _bilibiliLoading ? null : _queryBilibili,
            icon: const Icon(Icons.videocam, size: 18),
            label: Text(_bilibiliLoading ? '加载中...' : '验证网络'),
          ),
        ],
      ),
      body: Column(children: [
        // 输入区
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(children: [
            Row(children: [
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
          ]),
        ),
        const Divider(height: 1),

        // 结果区
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _bilibiliResult != null
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Text('B站热门视频 Top 10', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ..._bilibiliResult!.asMap().entries.map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SizedBox(
                              width: 24,
                              child: Text('${e.key + 1}.', style: const TextStyle(color: kMuted)),
                            ),
                            Expanded(child: Text('${e.value}', style: const TextStyle(fontSize: 13))),
                          ]),
                        )),
                      ],
                    )
                  : _error != null
                      ? Center(child: Text('❌ $_error', style: const TextStyle(color: kRedUp)))
                      : _result == null
                          ? const Center(child: Text('输入基金代码查询\n或点右上角"验证网络"测试接口', style: TextStyle(color: kMuted, fontSize: 16), textAlign: TextAlign.center))
                          : _buildResult(_result!),
        ),
      ]),
    );
  }

  Widget _buildResult(FundResult r) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _section('基金信息', [
          _row('名称', r.name),
          _row('代码', r.code),
          _row('状态', r.statusStr),
          _row('更新时间', r.updateTime),
        ]),
        const SizedBox(height: 12),
        if (r.nav != null) _section('最新净值', [
          _row('单位净值', r.nav!),
          if (r.navDate != null) _row('净值日期', r.navDate!),
        ]),
        const SizedBox(height: 12),
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
