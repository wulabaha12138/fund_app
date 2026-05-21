import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
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

  // --- 截断到指定位数（不四舍五入）---
  static double truncateTo(double value, int decimals) {
    final factor = _pow10(decimals);
    return (value * factor).truncateToDouble() / factor;
  }
  static double _pow10(int n) {
    double r = 1;
    for (int i = 0; i < n; i++) r *= 10;
    return r;
  }

  static String formatAmount(double value) {
    final parts = value.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final decPart = parts[1];
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write(',');
      buffer.write(intPart[i]);
    }
    return '$buffer.$decPart';
  }
  static String formatTruncated(double value, int decimals) {
    final truncated = truncateTo(value, decimals);
    return truncated.toStringAsFixed(decimals);
  }

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
      // Tencent stock quote format (0-indexed):
      // 0:market,1:name,2:code,3:price,4:yestClose,5:open,6:volume, ...
      // Actually the change percentage (涨跌幅) is at index 32 (the third-to-last 百分比字段)
      // Let's try multiple known positions: 32 is the standard change% for stocks
      // Other known formats use index 3 for price, 32 for change%, so try 32 first
      for (int idx in [32, 31, 33, 3]) {
        if (parts.length > idx) {
          String raw = parts[idx].trim().replaceAll('%', '');
          if (raw.isNotEmpty && raw != '--' && raw != '0.00') {
            final val = double.tryParse(raw);
            if (val != null && val.abs() < 100) return val;
          }
        }
      }
      // Last resort: find any field that looks like a stock change
      for (int i = 3; i < parts.length && i < 40; i++) {
        String raw = parts[i].trim().replaceAll('%', '');
        if (raw.isNotEmpty && raw != '--') {
          final val = double.tryParse(raw);
          if (val != null && val.abs() > 0.01 && val.abs() < 30) return val;
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
    estimatedChange = truncateTo(estimatedChange, 2); // 截断不四舍五入

    final navIsToday = isSameDay(navDate);
    final isAfter15 = now.hour >= 15;
    FundData fundData;
    if (session == '交易中' || session == '午休') {
      fundData = FundData(
        fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
        estimatedChange: estimatedChange,
        estimatedNav: nav != null ? truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4) : null,
        actualChange: null, isFinal: false,
        holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: session,
        networkError: globalError,
      );
    } else if (session == '已收盘') {
      // Fix 7: NAV日期是今天且有actualChange，显示最终净值
      if (navIsToday && actualChange != null) {
        fundData = FundData(
          fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
          estimatedChange: actualChange, estimatedNav: null, actualChange: actualChange,
          isFinal: true, holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '已收盘（最终）',
          networkError: globalError,
        );
      } else if (navIsToday && actualChange == null) {
        // Fix 6: 已收盘但净值未公布，仍然显示预估涨跌幅
        fundData = FundData(
          fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
          estimatedChange: estimatedChange,
          estimatedNav: nav != null ? truncateTo(truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4), 4) : null,
          actualChange: null, isFinal: false,
          holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '待公布净值',
          networkError: globalError,
        );
      } else if (!navIsToday && isAfter15) {
        // Fix 6 + Fix 7: 收盘后净值页显示昨天日期，仍然显示预估
        final statusText = (actualChange != null) ? '已收盘（最终）' : '待公布净值';
        final shownChange = actualChange ?? estimatedChange;
        fundData = FundData(
          fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
          estimatedChange: shownChange,
          estimatedNav: (nav != null && actualChange == null)
              ? truncateTo(truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4), 4)
              : null,
          actualChange: actualChange,
          isFinal: actualChange != null,
          holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: statusText,
          networkError: globalError,
        );
      } else {
        fundData = FundData(
          fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
          estimatedChange: estimatedChange,
          estimatedNav: nav != null ? truncateTo(truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4), 4) : null,
          actualChange: null, isFinal: false,
          holdings: holdings, totalPct: totalPct,
          updateTime: nowStr, status: '待公布净值',
          networkError: globalError,
        );
      }
    } else {
      final change = actualChange ?? estimatedChange;
      final statusText = actualChange != null ? '上交易日' : session;
      fundData = FundData(
        fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
        estimatedChange: change, estimatedNav: null, actualChange: actualChange,
        isFinal: actualChange != null, holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: statusText,
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
  bool _selectionMode = false;
  final Set<String> _selectedCodes = {};

  final _codeCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
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
    _codeCtrl.dispose();
    _amountCtrl.dispose();
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

  void _addFromBar() {
    final code = _codeCtrl.text.trim();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('代码错误，请重新输入基金代码！')));
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('代码错误，请重新输入基金代码！')));
      return;
    }
    // Fix 3: 检测代码是否已存在
    if (_savedFunds.any((f) => f.code == code)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('基金 $code 已存在列表中，如需修改请在列表中操作'),
      ));
      return;
    }
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    _codeCtrl.clear();
    _amountCtrl.clear();
    _addFundWithCheck(code, amount);
  }

  Future<void> _addFundWithCheck(String code, double amount) async {
    try {
      final result = await FundApi.query(code);
      if (result.fundName.startsWith('基金') && result.fundName.contains(code)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未查询到基金相关信息，请重新输入代码')));
        }
        return;
      }
      _addFund(code, amount);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('查询失败: ' + e.toString())));
      }
      return;
    }
  }

  Future<void> _addFund(String code, double amount) async {
    // Fix 3: 重复检测
    if (_savedFunds.any((f) => f.code == code)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('基金 $code 已存在列表中')));
      }
      return;
    }
    _savedFunds.add(SavedFund(code: code, amount: amount));
    _expanded[code] = false;
    await FundStore.save(_savedFunds);
    setState(() {});
    _querySingle(code);
  }

  // Fix 2 + Fix 5: 编辑金额，金额为0也可编辑，自动唤起输入法
  void _editAmount(String code, double currentAmount) {
    final ctrl = TextEditingController(
      text: currentAmount > 0 ? FundApi.formatTruncated(currentAmount, 2) : '',
    );
    showDialog(
      context: context,
      builder: (ctx) {
        Future.microtask(() {
          if (ctrl.text.isNotEmpty) {
            ctrl.selection = TextSelection(
              baseOffset: 0,
              extentOffset: ctrl.text.length,
            );
          }
        });
        return AlertDialog(
          title: const Text('修改金额'),
          content: SizedBox(
            width: 240,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '持有金额（元）'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                FocusScope.of(ctx).requestFocus(FocusNode());
                Navigator.pop(ctx);
              },
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final amt = double.tryParse(ctrl.text.trim()) ?? 0;
                FocusScope.of(ctx).requestFocus(FocusNode());
                Navigator.pop(ctx);
                final idx = _savedFunds.indexWhere((f) => f.code == code);
                if (idx >= 0) {
                  setState(() {
                    _savedFunds[idx] = SavedFund(code: code, amount: amt);
                  });
                  FundStore.save(_savedFunds);
                }
                if (_results[code] != null) _querySingle(code);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteFund(String code) async {
    _savedFunds.removeWhere((f) => f.code == code);
    _results.remove(code);
    _loading.remove(code);
    _expanded.remove(code);
    await FundStore.save(_savedFunds);
    setState(() {});
  }

  void _showDeleteSelectedConfirm() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除所选基金'),
        content: Text('确定删除选中的 ' + _selectedCodes.length.toString() + ' 只基金吗?'),
        actions: [
          TextButton(onPressed: () {
            FocusScope.of(ctx).requestFocus(FocusNode());
            Navigator.pop(ctx);
          }, child: const Text('取消')),
          TextButton(onPressed: () {
            Navigator.pop(ctx);
            _deleteSelected();
          }, child: const Text('确定', style: TextStyle(color: kRedUp))),
        ],
      ),
    );
  }

  void _deleteSelected() async {
    for (final code in _selectedCodes) {
      _savedFunds.removeWhere((f) => f.code == code);
      _results.remove(code);
      _loading.remove(code);
      _expanded.remove(code);
    }
    _selectedCodes.clear();
    _selectionMode = false;
    await FundStore.save(_savedFunds);
    setState(() {});
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
          TextButton(onPressed: () {
            FocusScope.of(ctx).requestFocus(FocusNode());
            Navigator.pop(ctx);
          }, child: const Text('取消')),
          TextButton(
            onPressed: () {
              final code = codeCtrl.text.trim();
              if (code.length != 6) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('请输入6位基金代码')));
                return;
              }
              // Fix 3: 检测重复
              if (_savedFunds.any((f) => f.code == code)) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('基金 $code 已存在')));
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

  // Fix 1: 顶部显示实时交易状态（替换"基金净值预估"），居中
  Widget _buildAppBarTitle() {
    final session = FundApi.getSessionLabel();
    String text;
    Color color;

    if (session == '交易中' || session == '午休') {
      text = '交易中';
      color = kRedUp;
    } else if (session == '已收盘') {
      text = '交易已结束';
      color = kTextMuted;
    } else {
      text = '闭市';
      color = kTextMuted;
    }

    return Center(
      child: Text(text, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _buildAppBarTitle(),
        centerTitle: true,
        leading: _selectionMode
            ? BackButton(
                onPressed: () {
                  setState(() {
                    _selectedCodes.clear();
                    _selectionMode = false;
                  });
                },
              )
            : null,
        leadingWidth: _selectionMode ? 48 : 0,
      ),
      body: PopScope(
        canPop: !_selectionMode,
        onPopInvoked: (didPop) {
          if (!didPop && _selectionMode) {
            setState(() {
              _selectedCodes.clear();
              _selectionMode = false;
            });
          }
        },
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        // Top input bar
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: kBorder)),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _codeCtrl,
                    decoration: const InputDecoration(
                      hintText: '基金代码',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLength: 6,
                    buildCounter: (_, {required int currentLength, required bool isFocused, int? maxLength}) => null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _amountCtrl,
                    decoration: const InputDecoration(
                      hintText: '金额(元)',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 22),
                  onPressed: _addFromBar,
                  tooltip: '添加基金',
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.refresh, size: 22),
                tooltip: '刷新',
                onPressed: _refreshAll,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(_selectionMode ? Icons.check_box : Icons.checklist, size: 22),
                tooltip: _selectionMode ? '完成多选' : '多选',
                onPressed: () {
                  setState(() {
                    if (_selectionMode) {
                      _selectedCodes.clear();
                      _selectionMode = false;
                    } else {
                      _selectionMode = true;
                    }
                  });
                },
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
              ),
              if (_selectionMode)
                IconButton(
                  icon: const Icon(Icons.delete_sweep, size: 22, color: Colors.red),
                  tooltip: '删除所选',
                  onPressed: _showDeleteSelectedConfirm,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  padding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
        // Fund list
        Expanded(
          child: _savedFunds.isEmpty
              ? const Center(
                  child: Text('输入基金代码点击 + 添加', style: TextStyle(color: kTextMuted, fontSize: 14)),
                )
              : RefreshIndicator(
                  onRefresh: () async => _refreshAll(),
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
                    itemCount: _savedFunds.length,
                    buildDefaultDragHandles: true,
                    proxyDecorator: (child, index, animation) => child,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex--;
                        final item = _savedFunds.removeAt(oldIndex);
                        _savedFunds.insert(newIndex, item);
                      });
                      FundStore.save(_savedFunds);
                    },
                    itemBuilder: (ctx, i) => _buildFundCard(_savedFunds[i]),
                  ),
                ),
        ),
      ],
    );
  }

    Widget _buildFundCard(SavedFund saved) {
    final code = saved.code;
    final data = _results[code];
    final isLoading = _loading[code] == true;
    final isExpanded = _expanded[code] ?? false;
    final isSelected = _selectedCodes.contains(code);

    return GestureDetector(
      key: ValueKey(code),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isSelected ? const BorderSide(color: kRedUp, width: 2) : BorderSide.none,
        ),
        elevation: 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            if (_selectionMode) {
              setState(() {
                if (_selectedCodes.contains(code)) {
                  _selectedCodes.remove(code);
                  if (_selectedCodes.isEmpty) _selectionMode = false;
                } else {
                  _selectedCodes.add(code);
                }
              });
            } else if (data == null && !isLoading) {
              _querySingle(code);
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: fund name + delete
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
                    if (!_selectionMode)
                      GestureDetector(
                        onTap: () => _showDeleteConfirm(code),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                            color: Color(0x22EF4444),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close, size: 14, color: Color(0xFFEF4444)),
                        ),
                      ),
                  ],
                ),
                if (data != null) ...[
                  const SizedBox(height: 10),
                  // Left: 净值信息 + 涨跌幅，Right: 持有金额 + 预估收益
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Left
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (data.nav != null)
                                  Flexible(
                                    child: Text(
                                      '净值 ${data.nav!} (${data.navDate ?? "--"})',
                                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                const SizedBox(width: 6),
                                Text(data.status, style: const TextStyle(fontSize: 11, color: kTextMuted)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                _changeWidget(data.estimatedChange, data.isFinal ? '' : '预估'),
                                if (data.estimatedNav != null) ...[
                                  const SizedBox(width: 10),
                                  Text(
                                    '≈ ${FundApi.formatTruncated(data.estimatedNav!, 4)}',
                                    style: const TextStyle(fontSize: 12, color: kTextMuted),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Right: 持有金额 + 预估收益
                      if (saved.amount > 0) ..._buildAmountAndEarnings(code, saved.amount, data) else
                        GestureDetector(
                          onTap: () => _editAmount(code, 0),
                          child: Text(
                            '点击设置持有金额',
                            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Divider(height: 1),
                  InkWell(
                    onTap: () => setState(() => _expanded[code] = !isExpanded),
                    child: Row(
                      children: [
                        Text('前十大持仓 (${FundApi.formatTruncated(data.totalPct, 1)}%)',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 20, color: kTextMuted),
                      ],
                    ),
                  ),
                  if (isExpanded) ...[
                    const SizedBox(height: 8),
                    if (data.holdings.isEmpty)
                      const Text('暂无持仓数据', style: TextStyle(color: kTextMuted, fontSize: 13))
                    else
                      ...data.holdings.asMap().entries.map((e) => _buildStockRow(e.key + 1, e.value)),
                  ],
                ] else ...[
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('点击加载', style: TextStyle(color: kTextMuted)),
                  ),
                ],
                if (data?.networkError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('⚠ ${data!.networkError}', style: const TextStyle(fontSize: 11, color: Colors.orange)),
                  ),
                if (data != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${data.updateTime}', style: const TextStyle(fontSize: 10, color: kTextMuted)),
                  ),
              ],
            ),
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
          '$sign${FundApi.formatTruncated(change, 2)}%',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  Widget _buildStockRow(int index, StockHolding s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text('$index', style: const TextStyle(fontSize: 12, color: kTextMuted)),
          ),
          Expanded(
            flex: 3,
            child: Text(s.name, style: const TextStyle(fontSize: 13)),
          ),
          Text('${FundApi.formatTruncated(s.pct, 1)}%', style: const TextStyle(fontSize: 12, color: kTextMuted)),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: _buildStockChange(s),
          ),
        ],
      ),
    );
  }

  Widget _buildStockChange(StockHolding s) {
    bool hasError = s.change == null;
    double changeVal = s.change ?? 0.0;
    final color = (!hasError && changeVal >= 0) ? kRedUp : kGreenDown;
    final sign = (!hasError && changeVal >= 0) ? '+' : '';
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (hasError)
          Tooltip(message: s.errorMsg ?? '失败', child: const Icon(Icons.error_outline, size: 14, color: Colors.orange))
        else
          Text('$sign${FundApi.formatTruncated(changeVal, 2)}%',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  // 持有金额（大号黑色，千分位）+ 预估/最终收益（小号）右侧垂直排列
  List<Widget> _buildAmountAndEarnings(String code, double amount, FundData data) {
    final isFinalValue = data.isFinal && data.nav != null;
    final change = isFinalValue ? (data.actualChange ?? data.estimatedChange) : data.estimatedChange;
    final earnings = amount * change / 100;
    final sign = earnings >= 0 ? '+' : '';
    final earnColor = earnings >= 0 ? kRedUp : kGreenDown;
    final earnLabel = isFinalValue ? '最终收益' : '预估收益';

    return [
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 持有金额 — 大号黑色（千分位）
          GestureDetector(
            onTap: () => _editAmount(code, amount),
            child: Text(
              '持有金额：${FundApi.formatAmount(amount)}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
          ),
          const SizedBox(height: 2),
          // 收益 — 小号
          Text(
            '$earnLabel：$sign${FundApi.formatTruncated(earnings, 2)}',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: earnColor),
          ),
        ],
      ),
    ];
  }

  void _showDeleteConfirm(String code) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除基金'),
        content: Text('确定删除基金 ' + code + ' 吗?'),
        actions: [
          TextButton(onPressed: () {
            FocusScope.of(ctx).requestFocus(FocusNode());
            Navigator.pop(ctx);
          }, child: const Text('取消')),
          TextButton(onPressed: () { Navigator.pop(ctx); _deleteFund(code); }, child: const Text('确定', style: TextStyle(color: kRedUp))),
        ],
      ),
    );
  }
}
