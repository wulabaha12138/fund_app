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
  final String? nav;
  final String? navDate;
  final double? estimateChange;
  final String estimateChangeLabel;
  final List<StockHolding> holdings;
  final double totalPct;
  final String updateTime;
  final String statusStr;
  // 调试信息
  final String debugInfo;

  FundResult({
    required this.name, required this.code,
    this.nav, this.navDate, this.estimateChange,
    required this.estimateChangeLabel,
    required this.holdings, required this.totalPct,
    required this.updateTime, required this.statusStr,
    required this.debugInfo,
  });
}

// ─── API ───
class FundApi {
  static const _ua = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36';
  static const _timeout = Duration(seconds: 15);

  /// 发送HTTP GET请求，不自动切换协议，只按原URL请求
  static Future<String> _get(String url) async {
    final headers = <String, String>{
      'User-Agent': _ua,
      'Accept': '*/*',
      'Referer': 'https://fund.eastmoney.com/',
    };
    final c = HttpClient()
      ..connectionTimeout = _timeout
      ..badCertificateCallback = (cert, host, port) => true;
    try {
      final rq = await c.getUrl(Uri.parse(url));
      headers.forEach((k, v) => rq.headers.set(k, v));
      final rp = await rq.close();
      if (rp.statusCode != 200) {
        throw Exception('HTTP ${rp.statusCode}');
      }
      return await rp.transform(utf8.decoder).join();
    } finally {
      c.close(force: true);
    }
  }

  /// 基金名称 + 净值 + 估算涨跌幅（fundgz 纯HTTP）
  static Future<Map<String, dynamic>> _fundgz(String code) async {
    try {
      final body = await _get('http://fundgz.1234567.com.cn/js/$code.js');
      final m = RegExp(r'jsonpgz\((.+)\)', dotAll: true).firstMatch(body);
      if (m == null) return {};
      return jsonDecode(m.group(1)!) as Map<String, dynamic>;
    } catch (e) {
      return {'_error': e.toString()};
    }
  }

  /// 持仓（fundf10 HTTPS）
  static Future<List<Map<String, dynamic>>> _holdings(String code) async {
    final url = 'https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$code&topline=10';
    try {
      final body = await _get(url);
      final cm = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (cm == null) return [];
      final html = cm.group(1)!;
      // 用分割法解析表格行
      final results = <Map<String, dynamic>>[];
      // 找 <tr>...</tr> 区块
      final trs = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true).allMatches(html);
      for (final tr in trs) {
        final trHtml = tr.group(1)!;
        // 提取股票代码: <a ...>600036</a>
        final codeMatch = RegExp(r'<a[^>]*>(\d{6})</a>').firstMatch(trHtml);
        if (codeMatch == null) continue;
        // 提取股票名称: <a ...>招商银行</a>
        final nameMatches = RegExp(r'<a[^>]*>([^<]+)</a>').allMatches(trHtml).toList();
        if (nameMatches.length < 2) continue;
        // 提取占比: <td class="tor">5.23%</td>  天天基金实际返回 class="tor"
        final pctMatch = RegExp(r'<td[^>]*class="tor"[^>]*>([\d\.]+)%').firstMatch(trHtml);
        if (pctMatch == null) continue;
        results.add({
          'code': codeMatch.group(1),
          'name': nameMatches[1].group(1)!.trim(),
          'pct': double.tryParse(pctMatch.group(1)!) ?? 0,
        });
      }
      return results;
    } catch (e) {
      return [];
    }
  }

  /// 股票涨跌幅（腾讯行情 HTTP）
  static Future<double?> _stockChange(String code) async {
    String pref;
    if (code.startsWith('6')) pref = 'sh';
    else if (code.startsWith('8') || code.startsWith('4')) pref = 'bj';
    else pref = 'sz';
    try {
      final body = await _get('http://qt.gtimg.cn/q=$pref$code');
      // 腾讯格式: v_sh600036="...~...~...~涨跌幅%"
      // 字段 32 = 涨跌幅%（0-indexed）
      final parts = body.split('~');
      if (parts.length > 32) {
        final v = parts[32].trim();
        final n = double.tryParse(v);
        if (n != null) return n;
      }
    } catch (_) {}
    return null;
  }

  static bool _isTradDay() => DateTime.now().weekday <= 5;

  static Future<FundResult> query(String code) async {
    final now = DateTime.now();
    final nowStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final debug = <String>[];

    // 1. fundgz
    debug.add('--- fundgz ---');
    final detail = await _fundgz(code);
    debug.add('fundgz raw: $detail');
    final name = detail['name'] ?? '基金$code';
    final nav = detail['dwjz'] as String?;
    final navDate = detail['jzrq'] as String?;
    final gszzl = detail['gszzl'] as String?; // 估算涨跌幅

    // 2. 持仓
    debug.add('--- holdings ---');
    final raw = await _holdings(code);
    debug.add('holdings count: ${raw.length}');
    final stocks = <StockHolding>[];
    double totalPct = 0;
    if (raw.isNotEmpty) {
      final changes = await Future.wait(raw.map((h) => _stockChange(h['code'])));
      for (int i = 0; i < raw.length; i++) {
        totalPct += raw[i]['pct'] as double;
        stocks.add(StockHolding(
          name: raw[i]['name'], code: raw[i]['code'],
          pct: raw[i]['pct'], change: changes[i],
        ));
        debug.add('  ${raw[i]['name']}: ${raw[i]['pct']}%, change=${changes[i]}');
      }
    }

    // 3. 状态
    final hm = now.hour * 60 + now.minute;
    bool marketOpen = _isTradDay() && ((hm >= 570 && hm <= 690) || (hm >= 780 && hm <= 900));

    String status;
    double? estChange;
    String changeLabel;

    if (!_isTradDay()) {
      status = '休市';
      estChange = null;
      changeLabel = '休市';
    } else if (marketOpen) {
      status = '交易中';
      estChange = gszzl != null ? double.tryParse(gszzl) : null;
      changeLabel = '实时估算';
    } else if (hm < 570) {
      status = '未开市';
      // 未开市时 fundgz 的 gszzl 是上交易日收盘时的估算值，也可以显示
      estChange = gszzl != null ? double.tryParse(gszzl) : null;
      changeLabel = estChange != null ? '上日估算' : '待开市';
    } else {
      status = '已收盘';
      estChange = null;
      changeLabel = '待公布净值';
    }

    return FundResult(
      name: name, code: code,
      nav: nav, navDate: navDate,
      estimateChange: estChange,
      estimateChangeLabel: changeLabel,
      holdings: stocks, totalPct: totalPct,
      updateTime: nowStr, statusStr: status,
      debugInfo: debug.join('\n'),
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
      return const Center(child: Text('输入基金代码查询', style: TextStyle(color: kMuted, fontSize: 16)));
    }
    return _buildResult(_result!);
  }

  Widget _buildResult(FundResult r) {
    final sign = r.estimateChange != null ? (r.estimateChange! >= 0 ? '+' : '') : '';
    final color = r.estimateChange != null ? (r.estimateChange! >= 0 ? kRedUp : kGreenDown) : kMuted;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ─── 基金信息 ───
        _card([
          Text(r.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
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

        // ─── 净值信息 ───
        _card([
          const Text('净值信息', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (r.nav != null) _infoRow('单位净值', r.nav!),
          if (r.navDate != null) _infoRow('净值日期', r.navDate!),
          _infoRow(
            '涨跌估算',
            r.estimateChange != null ? '$sign${r.estimateChange!.toStringAsFixed(2)}%' : '--',
            valueColor: color,
          ),
          _infoRow('说明', r.estimateChangeLabel, valueColor: kMuted),
        ]),

        const SizedBox(height: 10),

        // ─── 持仓股票 ───
        _card([
          Text('持仓股票 (${r.holdings.length}只)',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          if (r.holdings.isNotEmpty)
            Text('合计 ${r.totalPct.toStringAsFixed(1)}%', style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 8),
          if (r.holdings.isEmpty)
            const Text('未获取到持仓数据', style: TextStyle(color: kMuted, fontSize: 13))
          else
            ...r.holdings.map((s) {
              final sc = s.change != null ? (s.change! >= 0 ? kRedUp : kGreenDown) : kMuted;
              final ss = s.change != null ? (s.change! >= 0 ? '+' : '') : '';
              final ct = s.change != null ? '$ss${s.change!.toStringAsFixed(2)}%' : '--';
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(s.name, style: const TextStyle(fontSize: 13))),
                  SizedBox(width: 60, child: Text('${s.pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12, color: kMuted))),
                  SizedBox(width: 70, child: Text(ct, style: TextStyle(fontSize: 13, color: sc, fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
                ]),
              );
            }),
        ]),

        // ─── 调试信息 ───
        const SizedBox(height: 10),
        ExpansionTile(
          title: const Text('调试信息', style: TextStyle(fontSize: 13, color: kMuted)),
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(r.debugInfo, style: const TextStyle(fontSize: 10, color: kMuted, fontFamily: 'monospace')),
            ),
          ],
        ),
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

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: const TextStyle(color: kMuted, fontSize: 13))),
        Expanded(child: Text(value, style: TextStyle(fontSize: 14, color: valueColor))),
      ]),
    );
  }
}
