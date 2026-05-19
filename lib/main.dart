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

// ─── 数据 ───
class StockHolding {
  final String name;
  final String code;
  final double pct;
  final double? change; // null = 未获取到
  StockHolding({required this.name, required this.code, required this.pct, this.change});
}

class FundResult {
  final String name;
  final String code;
  final String? nav;        // 上交易日净值
  final String? navDate;    // 净值日期
  final double? change;     // 涨跌幅（今日实际或预估）
  final String changeLabel; // 涨跌幅说明
  final List<StockHolding> holdings;
  final double totalPct;
  final String updateTime;
  final String statusStr;

  FundResult({
    required this.name, required this.code,
    this.nav, this.navDate, this.change,
    required this.changeLabel,
    required this.holdings, required this.totalPct,
    required this.updateTime, required this.statusStr,
  });
}

// ─── API ───
class FundApi {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';
  static const _timeout = Duration(seconds: 10);

  static Future<String> _get(String url, {Map<String, String>? headers}) async {
    headers ??= {
      'User-Agent': _ua,
      'Accept': '*/*',
      'Referer': 'https://fund.eastmoney.com/',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    };
    for (var scheme in ['https', 'http']) {
      final u = url.replaceFirst(RegExp(r'^https?://'), '$scheme://');
      try {
        final c = HttpClient()..connectionTimeout = _timeout..badCertificateCallback = (a, b, c) => true;
        try {
          final rq = await c.getUrl(Uri.parse(u));
          headers!.forEach((k, v) => rq.headers.set(k, v));
          final rp = await rq.close();
          if (rp.statusCode == 200) {
            final body = await rp.transform(utf8.decoder).join();
            if (body.isNotEmpty) return body;
          }
        } finally { c.close(force: true); }
      } catch (_) {}
    }
    throw Exception('请求失败');
  }

  /// 天天基金 API：获取基金详情（净值、名称、涨跌幅）
  /// 接口: https://fundgz.1234567.com.cn/js/{code}.js
  static Future<Map<String, dynamic>> _fundDetail(String code) async {
    try {
      final body = await _get('http://fundgz.1234567.com.cn/js/$code.js');
      final m = RegExp(r'jsonpgz\((.+)\)').firstMatch(body);
      if (m != null) {
        return jsonDecode(m.group(1)!) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  /// 天天基金 API：获取基金持仓
  /// 接口: https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code={code}&topline=10
  static Future<List<Map<String, dynamic>>> _holdings(String code) async {
    try {
      final url = 'https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$code&topline=10';
      final body = await _get(url);
      final contentMatch = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (contentMatch == null) return [];
      final content = contentMatch.group(1)!;
      final rows = RegExp(
        r'<tr.*?><td.*?>(\d+)</td><td.*?><a[^>]*>(\d{6})</a></td><td.*?><a[^>]*>([^<]+)</a></td>.*?<td[^>]*class=[\'"]tor[\'"]>([\d\.]+)%',
        dotAll: true,
      ).allMatches(content);
      return rows.map((r) => <String, dynamic>{
        'code': r.group(2)!, 'name': r.group(3)!.trim(), 'pct': double.tryParse(r.group(4)!) ?? 0,
      }).toList();
    } catch (_) { return []; }
  }

  /// 腾讯行情：获取股票涨跌幅
  static Future<double?> _stockChange(String code) async {
    String pref;
    if (code.startsWith('6')) pref = 'sh';
    else if (code.startsWith('8') || code.startsWith('4')) pref = 'bj';
    else pref = 'sz';
    try {
      final body = await _get('http://qt.gtimg.cn/q=$pref$code');
      final parts = body.split('~');
      if (parts.length > 32) {
        final v = double.tryParse(parts[32].trim());
        if (v != null) return v;
      }
    } catch (_) {}
    return null;
  }

  /// 检查今天是否是交易日（简单判断：工作日）
  static bool _isTradingDay() {
    final wd = DateTime.now().weekday;
    return wd >= 1 && wd <= 5;
  }

  /// 查询基金
  static Future<FundResult> query(String code) async {
    final now = DateTime.now();
    final nowStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // 1. 基本信息
    final detail = await _fundDetail(code);
    final name = detail['name'] as String? ?? '基金$code';
    final dwjz = detail['dwjz'] as String?;        // 上交易日单位净值
    final jzrq = detail['jzrq'] as String?;         // 净值日期
    final gszzl = detail['gszzl'] as String?;       // 实时估算涨跌幅(%)
    final gztime = detail['gztime'] as String?;     // 估算时间

    // 2. 持仓
    final rawHoldings = await _holdings(code);
    final stocks = <StockHolding>[];
    double totalPct = 0;

    if (rawHoldings.isNotEmpty) {
      // 并发获取股票涨跌幅
      final changes = await Future.wait(
        rawHoldings.map((h) => _stockChange(h['code'] as String))
      );
      for (int i = 0; i < rawHoldings.length; i++) {
        final h = rawHoldings[i];
        final pct = h['pct'] as double;
        totalPct += pct;
        stocks.add(StockHolding(
          name: h['name'], code: h['code'], pct: pct, change: changes[i],
        ));
      }
    }

    // 3. 确定状态和涨跌幅
    final isTradingDay = _isTradingDay();
    final hourMin = now.hour * 60 + now.minute;
    bool isMarketOpen = false;  // 9:30-11:30 或 13:00-15:00
    bool isClosingPeriod = false; // 已收盘但净值未公布

    if (isTradingDay) {
      if (hourMin >= 570 && hourMin <= 690) isMarketOpen = true;
      else if (hourMin >= 780 && hourMin <= 900) isMarketOpen = true;
      else if (hourMin > 900) isClosingPeriod = true;
    }

    String status;
    double? displayChange;
    String changeLabel;

    if (!isTradingDay) {
      status = '休市';
      displayChange = null;
      changeLabel = '休市无数据';
    } else if (isMarketOpen) {
      status = '交易中';
      // 用实时估算涨跌幅
      displayChange = gszzl != null ? double.tryParse(gszzl) : null;
      changeLabel = '实时估算';
    } else if (hourMin < 570) {
      status = '未开市';
      // 未开市：显示上交易日数据
      displayChange = null;
      changeLabel = '等待开市';
    } else {
      status = '已收盘';
      displayChange = null;
      changeLabel = '待公布净值';
    }

    return FundResult(
      name: name, code: code,
      nav: dwjz, navDate: jzrq,
      change: displayChange,
      changeLabel: changeLabel,
      holdings: stocks, totalPct: totalPct,
      updateTime: gztime ?? nowStr, statusStr: status,
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
    final changeColor = r.change != null
        ? (r.change! >= 0 ? kRedUp : kGreenDown)
        : kMuted;
    final changeSign = r.change != null ? (r.change! >= 0 ? '+' : '') : '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 基金信息
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Row(children: [
              Text('[${r.code}]', style: const TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Text(r.statusStr, style: const TextStyle(fontSize: 11, color: kMuted)),
              ),
            ]),
            const Divider(height: 16),
            if (r.nav != null) ...[
              _infoRow('最新净值', r.nav!),
              if (r.navDate != null) _infoRow('净值日期', r.navDate!),
            ],
            if (r.change != null)
              _infoRow('涨跌幅', '$changeSign${r.change!.toStringAsFixed(2)}% ($changeLabel)',
                valueColor: changeColor),
            _infoRow('更新时间', r.updateTime),
          ]),
        ),
        const SizedBox(height: 12),
        // 持仓
        if (r.holdings.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('持仓股票 (${r.holdings.length}只 合计${r.totalPct.toStringAsFixed(1)}%)',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...r.holdings.map((s) {
                final sc = s.change != null
                    ? (s.change! >= 0 ? kRedUp : kGreenDown)
                    : kMuted;
                final ss = s.change != null ? (s.change! >= 0 ? '+' : '') : '';
                final changeText = s.change != null
                    ? '$ss${s.change!.toStringAsFixed(2)}%'
                    : '--';
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
                  ),
                  child: Row(children: [
                    Expanded(child: Text(s.name, style: const TextStyle(fontSize: 14))),
                    Text('${s.pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 13, color: kMuted)),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 65,
                      child: Text(changeText,
                        style: TextStyle(fontSize: 13, color: sc,
                          fontWeight: s.change != null ? FontWeight.bold : FontWeight.normal),
                        textAlign: TextAlign.right),
                    ),
                  ]),
                );
              }),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: const TextStyle(color: kMuted, fontSize: 13))),
        Expanded(child: Text(value, style: TextStyle(fontSize: 14, color: valueColor))),
      ]),
    );
  }
}
