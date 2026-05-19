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
  final double? change;
  StockHolding({required this.name, required this.code, required this.pct, this.change});
}

class FundResult {
  final String name;
  final String code;
  final String? nav;        // 净值
  final String? navDate;    // 净值日期
  final double? change;     // 涨跌幅
  final String changeLabel;
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
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';
  static const _timeout = Duration(seconds: 10);

  static Future<String> _get(String url, {Map<String, String>? headers}) async {
    // 按原始 URL 协议请求，不自动切换 http/https
    // 如失败，再尝试反向协议（Python 版不需要这一步，但 Flutter 上某些接口需）
    headers ??= {
      'User-Agent': _ua,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': 'https://fund.eastmoney.com/',
    };
    final uris = [url];
    // 如果 URL 有明确协议，也加一个反向协议尝试
    if (url.startsWith('http://')) uris.add(url.replaceFirst('http://', 'https://'));
    else if (url.startsWith('https://')) uris.add(url.replaceFirst('https://', 'http://'));

    for (final u in uris) {
      try {
        final c = HttpClient()
          ..connectionTimeout = _timeout
          ..badCertificateCallback = (cert, host, port) => true;
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

  /// 天天基金：基金详情 (fundgz)
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

  /// 东方财富：持仓 (fundf10)
  static Future<List<Map<String, dynamic>>> _holdings(String code) async {
    try {
      final url = 'https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$code&topline=10';
      final body = await _get(url);
      final cm = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (cm == null) return [];
      // 匹配 class="tor" 或 class='tor' 或 class=tor
      final rows = RegExp(
        r'<tr[^>]*><td[^>]*>\d+</td><td[^>]*><a[^>]*>(\d{6})</a></td><td[^>]*><a[^>]*>([^<]+)</a></td>[^<]*<td[^>]*class=["\']?tor["\']?[^>]*>([\d\.]+)%',
        dotAll: true,
      ).allMatches(cm.group(1)!);
      if (rows.isEmpty) return [];
      return rows.map((r) => <String, dynamic>{
        'code': r.group(1)!, 'name': r.group(2)!.trim(), 'pct': double.tryParse(r.group(3)!) ?? 0,
      }).toList();
    } catch (_) { return []; }
  }

  /// 腾讯行情：涨跌幅
  static Future<double?> _stockChange(String code) async {
    String pref;
    if (code.startsWith('6')) pref = 'sh';
    else if (code.startsWith('8') || code.startsWith('4')) pref = 'bj';
    else pref = 'sz';
    try {
      final body = await _get('http://qt.gtimg.cn/q=$pref$code');
      final parts = body.split('~');
      if (parts.length > 32) return double.tryParse(parts[32].trim());
    } catch (_) {}
    return null;
  }

  static bool _isTradDay() => DateTime.now().weekday <= 5;

  /// 查询
  static Future<FundResult> query(String code) async {
    final now = DateTime.now();
    final nowStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // 1. 基本信息
    final detail = await _fundDetail(code);
    final name = detail['name'] ?? '基金$code';
    final nav = detail['dwjz'] as String?;
    final navDate = detail['jzrq'] as String?;
    final gszzl = detail['gszzl'] as String?;

    // 2. 持仓
    final raw = await _holdings(code);
    final stocks = <StockHolding>[];
    double totalPct = 0;
    if (raw.isNotEmpty) {
      final changes = await Future.wait(raw.map((h) => _stockChange(h['code'])));
      for (int i = 0; i < raw.length; i++) {
        totalPct += raw[i]['pct'] as double;
        stocks.add(StockHolding(name: raw[i]['name'], code: raw[i]['code'], pct: raw[i]['pct'], change: changes[i]));
      }
    }

    // 3. 状态
    final hm = now.hour * 60 + now.minute;
    bool marketOpen = _isTradDay() && ((hm >= 570 && hm <= 690) || (hm >= 780 && hm <= 900));

    String status;
    double? displayChange;
    String changeLabel;

    if (!_isTradDay()) {
      status = '休市';
      displayChange = null;
      changeLabel = '休市';
    } else if (marketOpen) {
      status = '交易中';
      displayChange = gszzl != null ? double.tryParse(gszzl) : null;
      changeLabel = '实时估算';
    } else if (hm < 570) {
      status = '未开市';
      displayChange = null;
      changeLabel = '待开市';
    } else {
      status = '已收盘';
      displayChange = null;
      changeLabel = '待公布净值';
    }

    return FundResult(
      name: name, code: code,
      nav: nav, navDate: navDate,
      change: displayChange, changeLabel: changeLabel,
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
  final _ctrl = TextEditingController();
  FundResult? _result;
  bool _loading = false;
  String? _error;

  Future<void> _query() async {
    final code = _ctrl.text.trim();
    if (code.length != 6 || !RegExp(r'^\d{6}$').hasMatch(code)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入6位基金代码')));
      return;
    }
    setState(() { _loading = true; _error = null; _result = null; });
    try { _result = await FundApi.query(code); setState(() { _loading = false; }); }
    catch (e) { setState(() { _error = e.toString(); _loading = false; }); }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

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
                controller: _ctrl,
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
        Expanded(child: _buildBody()),
      ]),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('❌ $_error', style: const TextStyle(color: kRedUp)));
    if (_result == null) {
      return const Center(
        child: Text('输入基金代码查询', style: TextStyle(color: kMuted, fontSize: 16)),
      );
    }
    return _buildResult(_result!);
  }

  Widget _buildResult(FundResult r) {
    final changeColor = r.change != null ? (r.change! >= 0 ? kRedUp : kGreenDown) : kMuted;
    final changeSign = r.change != null ? (r.change! >= 0 ? '+' : '') : '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ─── 基金信息卡 ───
        _card([
          Text(r.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Row(children: [
            Text(r.code, style: const TextStyle(color: kMuted, fontSize: 13)),
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
            const Spacer(),
            Text(r.updateTime, style: const TextStyle(color: kMuted, fontSize: 11)),
          ]),
        ]),

        const SizedBox(height: 10),

        // ─── 净值信息卡 ───
        _card([
          const Text('净值信息', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (r.nav != null)
            _row('单位净值', r.nav!),
          if (r.navDate != null)
            _row('净值日期', r.navDate!),
          _row('涨跌估算', r.change != null
              ? '$changeSign${r.change!.toStringAsFixed(2)}% (${r.changeLabel})'
              : '-- (${r.changeLabel})',
            valueColor: r.change != null ? changeColor : null),
        ]),

        const SizedBox(height: 10),

        // ─── 持仓股票卡 ───
        _card([
          Text('持仓股票${r.holdings.isNotEmpty ? " (${r.holdings.length}只 合计${r.totalPct.toStringAsFixed(1)}%)" : ""}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (r.holdings.isEmpty)
            const Text('未获取到持仓数据', style: TextStyle(color: kMuted, fontSize: 13))
          else
            ...r.holdings.map((s) {
              final sc = s.change != null ? (s.change! >= 0 ? kRedUp : kGreenDown) : kMuted;
              final ss = s.change != null ? (s.change! >= 0 ? '+' : '') : '';
              final ct = s.change != null ? '$ss${s.change!.toStringAsFixed(2)}%' : '--';
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
                ),
                child: Row(children: [
                  Expanded(child: Text(s.name, style: const TextStyle(fontSize: 13))),
                  Text('${s.pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12, color: kMuted)),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 60,
                    child: Text(ct, style: TextStyle(fontSize: 13, color: sc, fontWeight: FontWeight.bold), textAlign: TextAlign.right),
                  ),
                ]),
              );
            }),
        ]),
      ]),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _row(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: const TextStyle(color: kMuted, fontSize: 13))),
        Expanded(child: Text(value, style: TextStyle(fontSize: 14, color: valueColor))),
      ]),
    );
  }
}
