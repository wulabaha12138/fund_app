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

// ── Constants ──
const Color kRedUp = Color(0xFFEF4444);
const Color kGreenDown = Color(0xFF10B981);
const Color kTextMuted = Color(0xFF64748B);
const Color kBorder = Color(0xFFE2E8F0);
const Color kEstimateTagBg = Color(0xFFFFF3E0);
const Color kEstimateTagText = Color(0xFFE65100);
const Color kHeaderBg = Color(0xFFF1F5F9);

// ── Time Helpers ──

bool isTradingDay(DateTime dt) =>
    dt.weekday >= DateTime.monday && dt.weekday <= DateTime.friday;

String getSessionLabel() {
  final now = DateTime.now();
  if (!isTradingDay(now)) return '休市';
  final t = now.hour * 60 + now.minute;
  if (t < 9 * 60 + 30) return '未开市';
  if (t <= 11 * 60 + 30) return '交易中';
  if (t < 13 * 60) return '午休';
  if (t <= 15 * 60) return '交易中';
  return '已收盘';
}

bool isTradingSession(String session) =>
    session == '交易中' || session == '午休';

String dateKey(DateTime dt) => DateFormat('yyyy-MM-dd').format(dt);

/// Last trading day before today.
String lastTradingDayKey(DateTime now) {
  DateTime d = now.subtract(const Duration(days: 1));
  int safety = 10;
  while (safety-- > 0 && !isTradingDay(d)) d = d.subtract(const Duration(days: 1));
  return dateKey(d);
}

// ── Models ──

class StockHolding {
  final String name;
  final String code;
  final double pct;
  final double? change;
  final String? errorMsg;
  StockHolding({required this.name, required this.code, required this.pct, this.change, this.errorMsg});
  Map<String, dynamic> toJson() => {'name': name, 'code': code, 'pct': pct, 'change': change};
  factory StockHolding.fromJson(Map<String, dynamic> j) => StockHolding(
    name: j['name'] as String,
    code: j['code'] as String,
    pct: (j['pct'] as num).toDouble(),
    change: j['change'] != null ? (j['change'] as num).toDouble() : null,
  );
}

class FundDailyRecord {
  final String dateKey;
  final String fundCode;
  final String fundName;
  final String? nav;
  final String? navDate;
  final double finalChange;
  final bool isFinal;
  final List<StockHolding> holdings;
  final double totalPct;
  final String updateTime;

  FundDailyRecord({
    required this.dateKey, required this.fundCode, required this.fundName,
    this.nav, this.navDate, required this.finalChange, required this.isFinal,
    required this.holdings, required this.totalPct, required this.updateTime,
  });

  Map<String, dynamic> toJson() => {
    'dateKey': dateKey, 'fundCode': fundCode, 'fundName': fundName,
    'nav': nav, 'navDate': navDate, 'finalChange': finalChange, 'isFinal': isFinal,
    'holdings': holdings.map((h) => h.toJson()).toList(), 'totalPct': totalPct, 'updateTime': updateTime,
  };

  factory FundDailyRecord.fromJson(Map<String, dynamic> j) => FundDailyRecord(
    dateKey: j['dateKey'] as String,
    fundCode: j['fundCode'] as String,
    fundName: j['fundName'] as String? ?? '基金${j['fundCode']}',
    nav: j['nav'] as String?, navDate: j['navDate'] as String?,
    finalChange: (j['finalChange'] as num).toDouble(),
    isFinal: j['isFinal'] as bool? ?? false,
    holdings: (j['holdings'] as List?)?.map((e) => StockHolding.fromJson(e as Map<String, dynamic>)).toList() ?? [],
    totalPct: (j['totalPct'] as num?)?.toDouble() ?? 0,
    updateTime: j['updateTime'] as String? ?? '',
  );
}

class FundDisplayData {
  final String fundName;
  final String fundCode;
  final String? nav;
  final String? navDate;
  final double currentChange;
  final String status;
  final List<StockHolding> holdings;
  final double totalPct;
  final String updateTime;
  final String? networkError;
  final bool isEstimated;
  final double? estimatedNav;

  FundDisplayData({
    required this.fundName, required this.fundCode, this.nav, this.navDate,
    required this.currentChange, required this.status, required this.holdings,
    required this.totalPct, required this.updateTime, this.networkError,
    required this.isEstimated, this.estimatedNav,
  });
}

class SavedFund {
  String code;
  double amount;
  SavedFund({required this.code, this.amount = 0.0});
  Map<String, dynamic> toJson() => {'code': code, 'amount': amount};
  factory SavedFund.fromJson(Map<String, dynamic> j) =>
      SavedFund(code: j['code'] as String, amount: (j['amount'] as num).toDouble());
}

// ── Persistence ──

class DailyStore {
  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  static Future<void> saveStockChanges(String date, Map<String, double?> changes) async {
    final prefs = await _prefs;
    final clean = <String, double>{};
    changes.forEach((k, v) { if (v != null) clean[k] = v; });
    await prefs.setString('stock_changes_$date', jsonEncode(clean));
  }

  static Future<Map<String, double>> loadStockChanges(String date) async {
    final prefs = await _prefs;
    final raw = prefs.getString('stock_changes_$date');
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      return d.map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) { return {}; }
  }

  static Future<void> saveFundDailyRecords(String date, List<FundDailyRecord> records) async {
    final prefs = await _prefs;
    await prefs.setString('fund_daily_$date', jsonEncode(records.map((r) => r.toJson()).toList()));
  }

  static Future<List<FundDailyRecord>> loadFundDailyRecords(String date) async {
    final prefs = await _prefs;
    final raw = prefs.getString('fund_daily_$date');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => FundDailyRecord.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static Future<void> saveDailyAmounts(String date, Map<String, double> amounts) async {
    final prefs = await _prefs;
    await prefs.setString('daily_amounts_$date', jsonEncode(amounts));
  }

  static Future<Map<String, double>> loadDailyAmounts(String date) async {
    final prefs = await _prefs;
    final raw = prefs.getString('daily_amounts_$date');
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      return d.map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) { return {}; }
  }
}

// ── API ──

class FundApi {
  static const _timeout = Duration(seconds: 20);
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';

  static double truncateTo(double v, int d) {
    final f = _pow10(d);
    return (v * f).truncateToDouble() / f;
  }
  static double _pow10(int n) { double r = 1; for (int i = 0; i < n; i++) r *= 10; return r; }

  static String formatAmount(double v) {
    if (v == 0) return '0.00';
    final abs = v.abs();
    final prefix = v < 0 ? '-' : '';
    final parts = abs.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write(',');
      buf.write(parts[0][i]);
    }
    return '$prefix$buf.${parts[1]}';
  }

  static String formatTruncated(double v, int d) => truncateTo(v, d).toStringAsFixed(d);

  static Future<String> _get(String url, {Map<String, String>? h}) async {
    h ??= {'User-Agent': _ua, 'Referer': 'https://fund.eastmoney.com/', 'Accept': 'text/html,*/*', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Connection': 'keep-alive'};
    try {
      final c = http.Client();
      final r = await c.get(Uri.parse(url.replaceFirst(RegExp(r'^https://'), 'http://')), headers: h).timeout(_timeout);
      if (r.statusCode == 200) return utf8.decode(r.bodyBytes);
    } catch (_) {}
    final c = http.Client();
    try {
      final r = await c.get(Uri.parse(url.replaceFirst(RegExp(r'^http://'), 'https://')), headers: h).timeout(_timeout);
      if (r.statusCode == 200) return utf8.decode(r.bodyBytes);
      throw Exception('HTTP ${r.statusCode}');
    } finally { c.close(); }
  }

  static Future<Uint8List> _getBytes(String url, {Map<String, String>? h}) async {
    h ??= {'User-Agent': _ua, 'Referer': 'https://fund.eastmoney.com/', 'Accept': '*/*'};
    try {
      final c = http.Client();
      final r = await c.get(Uri.parse(url.replaceFirst(RegExp(r'^https://'), 'http://')), headers: h).timeout(_timeout);
      if (r.statusCode == 200) return r.bodyBytes;
    } catch (_) {}
    final c = http.Client();
    try {
      final r = await c.get(Uri.parse(url.replaceFirst(RegExp(r'^http://'), 'https://')), headers: h).timeout(_timeout);
      if (r.statusCode == 200) return r.bodyBytes;
      throw Exception('HTTP ${r.statusCode}');
    } finally { c.close(); }
  }

  /// Check if a date string refers to today. Handles both yyyy-MM-dd and MM-dd formats.
  static bool isSameDay(String? s) {
    if (s == null || s.isEmpty) return false;
    try {
      DateTime p = DateFormat('yyyy-MM-dd').parseStrict(s);
      final n = DateTime.now();
      return p.year == n.year && p.month == n.month && p.day == n.day;
    } catch (_) {
      try {
        // Try MM-dd format (e.g., "05-25")
        final p = DateFormat('MM-dd').parse(s);
        final n = DateTime.now();
        return p.month == n.month && p.day == n.day;
      } catch (_) {
        return false;
      }
    }
  }

  static Future<double?> fetchStockChange(String code) async {
    final prefix = code.startsWith('6') ? 'sh' : (code.startsWith('8') || code.startsWith('4') ? 'bj' : 'sz');
    try {
      final bytes = await _getBytes('https://qt.gtimg.cn/q=$prefix$code');
      final parts = <String>[];
      int s = 0;
      for (int i = 0; i < bytes.length; i++) {
        if (bytes[i] == 0x7E) { parts.add(utf8.decode(bytes.sublist(s, i), allowMalformed: true)); s = i + 1; }
      }
      if (s < bytes.length) parts.add(utf8.decode(bytes.sublist(s), allowMalformed: true));
      for (final idx in [32, 31, 33, 3]) {
        if (parts.length > idx) {
          final raw = parts[idx].trim().replaceAll('%', '');
          if (raw.isNotEmpty && raw != '--' && raw != '0.00') {
            final v = double.tryParse(raw);
            if (v != null && v.abs() < 100) return v;
          }
        }
      }
      for (int i = 3; i < parts.length && i < 40; i++) {
        final raw = parts[i].trim().replaceAll('%', '');
        if (raw.isNotEmpty && raw != '--') {
          final v = double.tryParse(raw);
          if (v != null && v.abs() > 0.01 && v.abs() < 30) return v;
        }
      }
      return null;
    } catch (e) { throw Exception('$code: $e'); }
  }

  static Future<List<Map<String, dynamic>>> fetchHoldings(String fundCode) async {
    try {
      final body = await _get('https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$fundCode&topline=10');
      final m = RegExp(r'content:"([^"]+)"').firstMatch(body);
      if (m == null) return [];
      String c = m.group(1)!.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&');
      final reg = RegExp(r'''<tr.*?><td.*?>\d+</td><td.*?><a[^>]*>(\d{6})</a></td><td.*?><a[^>]*>([^<]+)</a></td>.*?<td[^>]*class=["']tor["']>([\d\.]+)%''', dotAll: true);
      return reg.allMatches(c).map((m) => <String, dynamic>{'code': m.group(1)!, 'name': m.group(2)!.trim(), 'pct': double.tryParse(m.group(3)!) ?? 0.0}).where((h) => (h['code'] as String).length == 6 && (h['pct'] as double) > 0).toList();
    } catch (_) { return []; }
  }

  static Future<Map<String, dynamic>> fetchBaseInfo(String fundCode) async {
    try {
      final html = await _get('https://fund.eastmoney.com/$fundCode.html');
      final nm = RegExp(r'<title>([^<]+?)\(\d{6}\)').firstMatch(html);
      final fundName = nm?.group(1)?.trim() ?? '基金$fundCode';
      String? nav, navDate;
      final nm1 = RegExp(r'单位净值[^)]*?\((\d{4}-\d{2}-\d{2})\)[^0-9]*?(\d+\.\d+)').firstMatch(html);
      if (nm1 != null) { navDate = nm1.group(1); nav = nm1.group(2); }
      else {
        final nm2 = RegExp(r'单位净值[^)]*?\((\d+-\d+)\)[^0-9]*?(\d+\.\d+)').firstMatch(html);
        if (nm2 != null) { navDate = nm2.group(1); nav = nm2.group(2); }
      }
      double? ac;
      if (nav != null) {
        final near = RegExp('${RegExp.escape(nav)}[^0-9]*?([+-]?\\d+\\.?\\d*)%').firstMatch(html);
        if (near != null) ac = double.tryParse(near.group(1)!);
        if (ac == null) {
          final dz = RegExp(r'dataOfFund.*?单位净值.*?([+-]?\d+\.?\d*)%', dotAll: true).firstMatch(html);
          if (dz != null) ac = double.tryParse(dz.group(1)!);
        }
      }
      return {'fundName': fundName, 'nav': nav, 'navDate': navDate, 'actualChange': ac};
    } catch (_) { return {'fundName': '基金$fundCode', 'nav': null, 'navDate': null, 'actualChange': null}; }
  }

  static Future<FundDisplayData> query({
    required String fundCode,
    required List<FundDailyRecord> todayRecords,
    required List<FundDailyRecord> prevRecords,
    required Map<String, double> todayStockChanges,
    required bool forceRefresh,
  }) async {
    final now = DateTime.now();
    final today = dateKey(now);
    final session = getSessionLabel();
    final nowStr = DateFormat('HH:mm').format(now);
    String? globalError;

    final cached = todayRecords.where((r) => r.fundCode == fundCode).toList();

    // ── Outside trading hours: use cached data (unless force refresh) ──
    if (!forceRefresh && !isTradingSession(session) && cached.isNotEmpty) {
      final r = cached.first;
      // If cached data is already final (NAV published), return it.
      // If session is '已收盘' and NAV wasn't published yet, fall through to check.
      if (r.isFinal) {
        return FundDisplayData(
          fundName: r.fundName, fundCode: r.fundCode, nav: r.nav, navDate: r.navDate,
          currentChange: r.finalChange,
          status: '已收盘（最终）',
          holdings: r.holdings, totalPct: r.totalPct, updateTime: r.updateTime, isEstimated: false,
        );
      }
      if (session != '已收盘') {
        // 未开市/休市: show cached data
        return FundDisplayData(
          fundName: r.fundName, fundCode: r.fundCode, nav: r.nav, navDate: r.navDate,
          currentChange: r.finalChange,
          status: session,
          holdings: r.holdings, totalPct: r.totalPct, updateTime: r.updateTime, isEstimated: !r.isFinal,
        );
      }
      // 已收盘 but cache is not final: fall through to re-fetch (NAV might be out now)
    }

    // ── Fetch live ──
    Map<String, dynamic> base;
    try { base = await fetchBaseInfo(fundCode); }
    catch (e) {
      globalError = '基本信息失败: $e';
      base = {'fundName': '基金$fundCode', 'nav': null, 'navDate': null, 'actualChange': null};
    }
    final fundName = base['fundName'];
    final nav = base['nav'] as String?;
    final navDate = base['navDate'] as String?;
    final actualChange = base['actualChange'] as double?;

    List<Map<String, dynamic>> rawHoldings = [];
    try { rawHoldings = await fetchHoldings(fundCode); }
    catch (e) {
      if (globalError == null) globalError = '持仓失败: $e';
      if (cached.isNotEmpty) rawHoldings = cached.first.holdings.map((h) => {'code': h.code, 'name': h.name, 'pct': h.pct}).toList();
      else if (prevRecords.isNotEmpty) {
        final p = prevRecords.where((r) => r.fundCode == fundCode).toList();
        if (p.isNotEmpty) rawHoldings = p.first.holdings.map((h) => {'code': h.code, 'name': h.name, 'pct': h.pct}).toList();
      }
    }

    List<StockHolding> holdings = [];
    double totalPct = 0, weightedChange = 0;
    int successCount = 0;
    final newChanges = <String, double?>{};

    for (final h in rawHoldings) {
      final pct = (h['pct'] as num).toDouble();
      totalPct += pct;
      final code = h['code'] as String;
      double? change = todayStockChanges[code];
      if (change == null) {
        try { change = await fetchStockChange(code); } catch (_) {}
        if (change == null && cached.isNotEmpty) {
          final ch = cached.first.holdings.where((s) => s.code == code).toList();
          if (ch.isNotEmpty) change = ch.first.change;
        }
      }
      newChanges[code] = change;
      if (change != null) { weightedChange += pct * change; successCount++; }
      holdings.add(StockHolding(name: h['name'], code: code, pct: pct, change: change));
    }

    double estimatedChange = (totalPct > 0 && successCount > 0) ? truncateTo(weightedChange / 100.0, 2) : 0.0;

    FundDailyRecord record;
    FundDisplayData display;

    if (isTradingSession(session)) {
      record = FundDailyRecord(dateKey: today, fundCode: fundCode, fundName: fundName, nav: nav, navDate: navDate, finalChange: estimatedChange, isFinal: false, holdings: holdings, totalPct: totalPct, updateTime: nowStr);
      display = FundDisplayData(fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate, currentChange: estimatedChange, status: session == '午休' ? '午休' : '交易中', holdings: holdings, totalPct: totalPct, updateTime: nowStr, isEstimated: true, estimatedNav: nav != null ? truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4) : null, networkError: globalError);
    } else if (session == '已收盘') {
      // After 15:00, whatever actualChange the page returns IS the final NAV.
      // 东方财富页面不会给预估值 — 要么没有值(null)，要么就是最终值。
      if (actualChange != null) {
        record = FundDailyRecord(dateKey: today, fundCode: fundCode, fundName: fundName, nav: nav, navDate: navDate, finalChange: actualChange, isFinal: true, holdings: holdings, totalPct: totalPct, updateTime: nowStr);
        display = FundDisplayData(fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate, currentChange: actualChange, status: '已收盘（最终）', holdings: holdings, totalPct: totalPct, updateTime: nowStr, isEstimated: false, networkError: globalError);
      } else {
        // 页面还没有更新当日净值，用持仓股票估算(15点后股票涨跌幅已是最终值)
        record = FundDailyRecord(dateKey: today, fundCode: fundCode, fundName: fundName, nav: nav, navDate: navDate, finalChange: estimatedChange, isFinal: false, holdings: holdings, totalPct: totalPct, updateTime: nowStr);
        display = FundDisplayData(fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate, currentChange: estimatedChange, status: '待公布净值', holdings: holdings, totalPct: totalPct, updateTime: nowStr, isEstimated: true, estimatedNav: nav != null ? truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4) : null, networkError: globalError);
      }
    } else {
      // 未开市 / 休市
      if (prevRecords.isNotEmpty) {
        final p = prevRecords.where((r) => r.fundCode == fundCode).toList();
        if (p.isNotEmpty) {
          final pr = p.first;
          if (newChanges.isNotEmpty) { final m = Map<String, double>.from(todayStockChanges); newChanges.forEach((k, v) { if (v != null) m[k] = v; }); await DailyStore.saveStockChanges(today, m); }
          final all = [...todayRecords.where((r) => r.fundCode != fundCode), pr];
          await DailyStore.saveFundDailyRecords(today, all);
          return FundDisplayData(fundName: pr.fundName, fundCode: pr.fundCode, nav: pr.nav, navDate: pr.navDate, currentChange: pr.finalChange, status: session, holdings: pr.holdings, totalPct: pr.totalPct, updateTime: pr.updateTime, isEstimated: !pr.isFinal, networkError: globalError);
        }
      }
      record = FundDailyRecord(dateKey: today, fundCode: fundCode, fundName: fundName, nav: nav, navDate: navDate, finalChange: actualChange ?? estimatedChange, isFinal: actualChange != null, holdings: holdings, totalPct: totalPct, updateTime: nowStr);
      display = FundDisplayData(fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate, currentChange: actualChange ?? estimatedChange, status: session, holdings: holdings, totalPct: totalPct, updateTime: nowStr, isEstimated: actualChange == null, networkError: globalError);
    }

    // ── Persist ──
    if (newChanges.isNotEmpty) {
      final merged = Map<String, double>.from(todayStockChanges);
      newChanges.forEach((k, v) { if (v != null) merged[k] = v; });
      await DailyStore.saveStockChanges(today, merged);
    }
    final allToday = [...todayRecords.where((r) => r.fundCode != fundCode), record];
    await DailyStore.saveFundDailyRecords(today, allToday);
    return display;
  }
}

// ── Fund Store ──

class FundStore {
  static Future<List<SavedFund>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('funds');
    if (raw == null || raw.isEmpty) return [];
    try { final list = jsonDecode(raw) as List; return list.map((e) => SavedFund.fromJson(e as Map<String, dynamic>)).toList(); }
    catch (_) { return []; }
  }
  static Future<void> save(List<SavedFund> funds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('funds', jsonEncode(funds.map((f) => f.toJson()).toList()));
  }
}

// ════════════════════════════════════════════════════════════
//  UI
// ════════════════════════════════════════════════════════════

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<SavedFund> _savedFunds = [];
  Map<String, FundDisplayData?> _results = {};
  Map<String, bool> _loading = {};
  Map<String, bool> _expanded = {};
  bool _selectionMode = false;
  final Set<String> _selectedCodes = {};

  List<FundDailyRecord> _todayRecords = [];
  List<FundDailyRecord> _prevRecords = [];
  Map<String, double> _todayStockChanges = {};
  Map<String, double> _todayAmounts = {};

  final _codeCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  Timer? _autoRefreshTimer;
  bool _initialLoading = false;

  @override
  void initState() { super.initState(); _loadSaved(); _startAutoRefresh(); }

  @override
  void dispose() { _autoRefreshTimer?.cancel(); _codeCtrl.dispose(); _amountCtrl.dispose(); super.dispose(); }

  /// Calculate today's amounts with carryover from previous trading day.
  Future<void> _computeTodayAmounts() async {
    if (_savedFunds.isEmpty) return;
    final today = dateKey(DateTime.now());

    if (_todayAmounts.isNotEmpty) {
      for (final f in _savedFunds) { if (!_todayAmounts.containsKey(f.code)) _todayAmounts[f.code] = f.amount; }
      return;
    }

    final lastDay = lastTradingDayKey(DateTime.now());
    final prevAmts = await DailyStore.loadDailyAmounts(lastDay);
    final prevRecs = _prevRecords.isNotEmpty ? _prevRecords : await DailyStore.loadFundDailyRecords(lastDay);

    final newAmts = <String, double>{};
    for (final f in _savedFunds) {
      double base = prevAmts[f.code] ?? f.amount;
      if (base > 0) {
        final pfr = prevRecs.where((r) => r.fundCode == f.code).toList();
        if (pfr.isNotEmpty) { base = FundApi.truncateTo(base + base * pfr.first.finalChange / 100.0, 2); }
      }
      newAmts[f.code] = base;
    }

    _todayAmounts = newAmts;
    await DailyStore.saveDailyAmounts(today, newAmts);
    for (int i = 0; i < _savedFunds.length; i++) {
      if (_todayAmounts.containsKey(_savedFunds[i].code)) _savedFunds[i].amount = _todayAmounts[_savedFunds[i].code]!;
    }
    await FundStore.save(_savedFunds);
  }

  double _getTodayAmount(String code) => _todayAmounts[code] ?? _savedFunds.where((f) => f.code == code).fold(0.0, (p, f) => f.amount);

  double _totalHoldings() => _savedFunds.fold(0.0, (s, f) => s + _getTodayAmount(f.code));
  double _totalEarnings() {
    double t = 0;
    for (final f in _savedFunds) {
      final amt = _getTodayAmount(f.code);
      final data = _results[f.code];
      if (data != null && amt > 0) t += amt * data.currentChange / 100.0;
    }
    return t;
  }
  /// Checks if any fund data is estimated (rather than final).
  bool get _hasAnyEstimated => _savedFunds.any((f) => (_results[f.code]?.isEstimated ?? false) && _results[f.code] != null);

  Future<void> _loadSaved() async {
    final funds = await FundStore.load();
    final now = DateTime.now();
    final today = dateKey(now);
    final lastDay = lastTradingDayKey(now);

    _todayRecords = await DailyStore.loadFundDailyRecords(today);
    _prevRecords = await DailyStore.loadFundDailyRecords(lastDay);
    _todayStockChanges = await DailyStore.loadStockChanges(today);
    _todayAmounts = await DailyStore.loadDailyAmounts(today);

    setState(() { _savedFunds = funds; _initialLoading = false; });
    if (funds.isNotEmpty) {
      await _computeTodayAmounts();
      _refreshAll();
    }
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (!mounted || _savedFunds.isEmpty) return;
      // Only auto-refresh during trading hours (9:30-15:00 on trading days)
      final session = getSessionLabel();
      if (isTradingSession(session)) _refreshAll();
    });
  }

  Future<void> _refreshAll({bool force = false}) async {
    for (var f in _savedFunds) { _querySingle(f.code, forceRefresh: force); }
  }

  Future<void> _querySingle(String code, {bool forceRefresh = false}) async {
    if (_loading[code] == true) return;
    setState(() => _loading[code] = true);
    try {
      final result = await FundApi.query(
        fundCode: code,
        todayRecords: _todayRecords,
        prevRecords: _prevRecords,
        todayStockChanges: _todayStockChanges,
        forceRefresh: forceRefresh,
      );
      setState(() { _results[code] = result; _loading[code] = false; });
      // Update local records from query result
      final today = dateKey(DateTime.now());
      _todayRecords = await DailyStore.loadFundDailyRecords(today);
      _todayStockChanges = await DailyStore.loadStockChanges(today);
    } catch (e) {
      setState(() {
        _results[code] = FundDisplayData(
          fundName: '基金$code', fundCode: code, currentChange: 0,
          status: '网络异常', holdings: [], totalPct: 0,
          updateTime: '', isEstimated: true, networkError: e.toString(),
        );
        _loading[code] = false;
      });
    }
  }

  void _addFromBar() {
    // Dismiss keyboard
    FocusScope.of(context).requestFocus(FocusNode());
    final code = _codeCtrl.text.trim();
    if (code.length != 6 || !RegExp(r'^\d{6}$').hasMatch(code)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('代码错误，请重新输入基金代码！')));
      return;
    }
    if (_savedFunds.any((f) => f.code == code)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('基金 $code 已存在列表中，如需修改请在列表中操作')));
      return;
    }
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    _codeCtrl.clear(); _amountCtrl.clear();
    _addFundWithCheck(code, amount);
  }

  Future<void> _addFundWithCheck(String code, double amount) async {
    await _addFund(code, amount);
  }

  Future<void> _addFund(String code, double amount) async {
    if (_savedFunds.any((f) => f.code == code)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('基金 $code 已存在列表中')));
      return;
    }
    _savedFunds.add(SavedFund(code: code, amount: amount));
    _expanded[code] = false;
    _todayAmounts[code] = amount;
    final today = dateKey(DateTime.now());
    await DailyStore.saveDailyAmounts(today, _todayAmounts);
    await FundStore.save(_savedFunds);
    setState(() {});
    // Small delay to let the widget rebuild with the new row, then fetch data
    await Future.delayed(const Duration(milliseconds: 100));
    _querySingle(code, forceRefresh: true);
  }

  void _editAmount(String code, double currentAmount) {
    final ctrl = TextEditingController(text: currentAmount > 0 ? FundApi.formatTruncated(currentAmount, 2) : '');
    showDialog(
      context: context,
      builder: (ctx) {
        Future.microtask(() {
          if (ctrl.text.isNotEmpty) ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
        });
        return AlertDialog(
          title: const Text('修改持有金额'),
          content: SizedBox(width: 240, child: TextField(
            controller: ctrl, autofocus: true,
            decoration: const InputDecoration(labelText: '持有金额（元）'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
          )),
          actions: [
            TextButton(onPressed: () { FocusScope.of(ctx).requestFocus(FocusNode()); Navigator.pop(ctx); }, child: const Text('取消')),
            TextButton(onPressed: () {
              final amt = double.tryParse(ctrl.text.trim()) ?? 0;
              FocusScope.of(ctx).requestFocus(FocusNode()); Navigator.pop(ctx);
              final idx = _savedFunds.indexWhere((f) => f.code == code);
              if (idx >= 0) {
                _savedFunds[idx] = SavedFund(code: code, amount: amt);
                _todayAmounts[code] = amt;
                final today = dateKey(DateTime.now());
                DailyStore.saveDailyAmounts(today, _todayAmounts);
                FundStore.save(_savedFunds);
              }
              if (_results[code] != null) _querySingle(code, forceRefresh: true);
            }, child: const Text('确定')),
          ],
        );
      },
    );
  }

  Future<void> _deleteFund(String code) async {
    _savedFunds.removeWhere((f) => f.code == code);
    _results.remove(code); _loading.remove(code); _expanded.remove(code);
    _todayAmounts.remove(code);
    final today = dateKey(DateTime.now());
    await DailyStore.saveDailyAmounts(today, _todayAmounts);
    await FundStore.save(_savedFunds);
    setState(() {});
  }

  void _showDeleteSelectedConfirm() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除所选基金'),
        content: Text('确定删除选中的 ${_selectedCodes.length} 只基金吗?'),
        actions: [
          TextButton(onPressed: () { FocusScope.of(ctx).requestFocus(FocusNode()); Navigator.pop(ctx); }, child: const Text('取消')),
          TextButton(onPressed: () { Navigator.pop(ctx); _deleteSelected(); }, child: const Text('确定', style: TextStyle(color: kRedUp))),
        ],
      ),
    );
  }

  void _deleteSelected() async {
    for (final code in _selectedCodes) {
      _savedFunds.removeWhere((f) => f.code == code);
      _results.remove(code); _loading.remove(code); _expanded.remove(code);
      _todayAmounts.remove(code);
    }
    _selectedCodes.clear(); _selectionMode = false;
    final today = dateKey(DateTime.now());
    await DailyStore.saveDailyAmounts(today, _todayAmounts);
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
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: codeCtrl,
            decoration: const InputDecoration(labelText: '基金代码', border: OutlineInputBorder(), isDense: true),
            keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 6,
            buildCounter: (_, {required int currentLength, required bool isFocused, int? maxLength}) => null,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: amountCtrl,
            decoration: const InputDecoration(labelText: '持有金额（元，可选）', border: OutlineInputBorder(), isDense: true),
            keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
          ),
        ]),
        actions: [
          TextButton(onPressed: () { FocusScope.of(ctx).requestFocus(FocusNode()); Navigator.pop(ctx); }, child: const Text('取消')),
          TextButton(onPressed: () {
            final code = codeCtrl.text.trim();
            if (code.length != 6) { ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('请输入6位基金代码'))); return; }
            if (_savedFunds.any((f) => f.code == code)) { ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('基金 $code 已存在'))); return; }
            final amount = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
            Navigator.pop(ctx);
            _addFund(code, amount);
          }, child: const Text('添加')),
        ],
      ),
    );
  }

  Widget _buildAppBarTitle() {
    final session = getSessionLabel();
    Map<String, dynamic> info;
    if (session == '交易中') info = {'text': '交易中', 'color': kRedUp};
    else if (session == '午休') info = {'text': '休息中', 'color': kTextMuted};
    else if (session == '已收盘') info = {'text': '交易已结束', 'color': kTextMuted};
    else if (session == '未开市') info = {'text': '未开市', 'color': kTextMuted};
    else info = {'text': '休市', 'color': kTextMuted};
    return Center(child: Text(info['text'] as String, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: info['color'] as Color)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _buildAppBarTitle(),
        centerTitle: true,
        leading: _selectionMode
            ? BackButton(onPressed: () { setState(() { _selectedCodes.clear(); _selectionMode = false; }); })
            : null,
        leadingWidth: _selectionMode ? 48 : 0,
      ),
      body: PopScope(
        canPop: !_selectionMode,
        onPopInvoked: (didPop) { if (!didPop && _selectionMode) setState(() { _selectedCodes.clear(); _selectionMode = false; }); },
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final session = getSessionLabel();
    return Column(
      children: [
        // Input bar
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: kBorder))),
          child: Row(children: [
            Expanded(flex: 3, child: SizedBox(height: 40, child: TextField(
              controller: _codeCtrl,
              decoration: const InputDecoration(hintText: '基金代码', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
              keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], maxLength: 6,
              buildCounter: (_, {required int currentLength, required bool isFocused, int? maxLength}) => null,
            ))),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: SizedBox(height: 40, child: TextField(
              controller: _amountCtrl,
              decoration: const InputDecoration(hintText: '金额(元)', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
              keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
            ))),
            const SizedBox(width: 4),
            IconButton(icon: const Icon(Icons.add_circle_outline, size: 22), onPressed: _addFromBar, tooltip: '添加基金', constraints: const BoxConstraints(minWidth: 40, minHeight: 40), padding: EdgeInsets.zero),
            const SizedBox(width: 4),
            IconButton(icon: const Icon(Icons.refresh, size: 22), tooltip: '刷新', onPressed: () => _refreshAll(force: true), constraints: const BoxConstraints(minWidth: 40, minHeight: 40), padding: EdgeInsets.zero),
            const SizedBox(width: 4),
            IconButton(icon: Icon(_selectionMode ? Icons.check_box : Icons.checklist, size: 22), tooltip: _selectionMode ? '完成多选' : '多选', onPressed: () { setState(() { if (_selectionMode) { _selectedCodes.clear(); _selectionMode = false; } else { _selectionMode = true; } }); }, constraints: const BoxConstraints(minWidth: 40, minHeight: 40), padding: EdgeInsets.zero),
            if (_selectionMode) IconButton(icon: const Icon(Icons.delete_sweep, size: 22, color: Colors.red), tooltip: '删除所选', onPressed: _showDeleteSelectedConfirm, constraints: const BoxConstraints(minWidth: 40, minHeight: 40), padding: EdgeInsets.zero),
          ]),
        ),
        // Summary bar — always show
        _buildSummaryBar(),
        // Fund table
        Expanded(
          child: _savedFunds.isEmpty
              ? const Center(child: Text('输入基金代码点击 + 添加', style: TextStyle(color: kTextMuted, fontSize: 14)))
              : RefreshIndicator(
                  onRefresh: () async => _refreshAll(force: true),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                    itemCount: _savedFunds.length + 1, // +1 for table header
                    itemBuilder: (ctx, i) {
                      if (i == 0) return _buildTableHeader();
                      return _buildFundRow(i - 1, _savedFunds[i - 1], session);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  // ── Summary Bar (always visible, white background) ──
  Widget _buildSummaryBar() {
    final totalHoldings = _totalHoldings();
    final totalEarnings = _totalEarnings();
    final session = getSessionLabel();
    final hasActiveData = session == '交易中' || session == '午休' || session == '已收盘';
    final showData = _savedFunds.isNotEmpty && hasActiveData;

    final earnColor = totalEarnings >= 0 ? kRedUp : kGreenDown;
    final earnSign = totalEarnings >= 0 ? '+' : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(color: Colors.white),
      child: Row(
        children: [
          // Total holdings
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('持有金额', style: TextStyle(fontSize: 12, color: kTextMuted)),
              const SizedBox(height: 2),
              Text('¥${FundApi.formatAmount(totalHoldings)}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF2D3748))),
            ]),
          ),
          // Vertical divider
          Container(width: 1, height: 36, color: kBorder, margin: const EdgeInsets.symmetric(horizontal: 12)),
          // Total earnings
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                const Text('总收益', style: TextStyle(fontSize: 12, color: kTextMuted)),
                if (showData && _hasAnyEstimated) ...[const SizedBox(width: 4), _buildEstimateTag()],
              ]),
              const SizedBox(height: 2),
              Text(
                showData ? '$earnSign¥${FundApi.formatAmount(totalEarnings)}' : '¥0.00',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: showData ? earnColor : kTextMuted),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  // ── Table Header ──
  Widget _buildTableHeader() {
    return Container(
      key: const ValueKey('table_header'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: Color(0xFFEDF2F7),
        border: Border(bottom: BorderSide(color: Color(0xFFCBD5E0), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('名称',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF4A5568)))),
          Expanded(flex: 3, child: Text('金额/昨日收益', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF4A5568)))),
          Expanded(flex: 4, child: Align(
            alignment: Alignment.centerRight,
            child: Text('今日收益率/收益',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF4A5568))),
          )),
        ],
      ),
    );
  }

  // ── Fund Row (table row style) ──
  Widget _buildFundRow(int listIdx, SavedFund saved, String session) {
    // listIdx is unused now; kept for API consistency
    final code = saved.code;
    final data = _results[code];
    final isLoading = _loading[code] == true;
    final isExpanded = _expanded[code] ?? false;
    final isSelected = _selectedCodes.contains(code);
    final amount = _getTodayAmount(code);
    final hasActiveData = session == '交易中' || session == '午休' || session == '已收盘';
    // Today's change: only show real data during trading hours or after close
    final displayChange = data != null && hasActiveData ? data.currentChange : 0.0;
    final earnings = hasActiveData && data != null && amount > 0 ? amount * data.currentChange / 100.0 : 0.0;
    final earnColor = earnings >= 0 ? kRedUp : kGreenDown;
    final earnSign = earnings >= 0 ? '+' : '';

    // Previous day change for details section
    double prevChange = 0;
    bool hasPrevData = false;
    if (_prevRecords.isNotEmpty) {
      final prev = _prevRecords.where((r) => r.fundCode == code).toList();
      if (prev.isNotEmpty) { prevChange = prev.first.finalChange; hasPrevData = true; }
    }
    // Fallback: if no prevRecords but data has a non-estimated currentChange, use it as prev day
    if (!hasPrevData && data != null && !data.isEstimated) {
      prevChange = data.currentChange;
      hasPrevData = true;
    }
    final prevColor = prevChange >= 0 ? kRedUp : kGreenDown;
    final prevSign = prevChange >= 0 ? '+' : '';
    final prevChangeText = hasPrevData ? '$prevSign${FundApi.formatTruncated(prevChange, 2)}%' : '--';
    // Previous day amount for compute
    double prevAmount = amount;
    double prevEarnings = 0;
    if (hasPrevData) {
      final prev = _prevRecords.where((r) => r.fundCode == code).toList();
      if (prev.isNotEmpty) {
        prevEarnings = prevAmount * prev.first.finalChange / 100.0;
      }
    }
    final prevEarnSign = prevEarnings >= 0 ? '+' : '';
    final prevEarnColor = prevEarnings >= 0 ? kRedUp : kGreenDown;

    return Column(
      key: ValueKey('row_$code'),
      children: [
          Container(
            color: isSelected ? const Color(0xFFFFF5F5) : null,
            child: InkWell(
              onTap: () {
              if (_selectionMode) {
                setState(() {
                  if (_selectedCodes.contains(code)) { _selectedCodes.remove(code); if (_selectedCodes.isEmpty) _selectionMode = false; }
                  else _selectedCodes.add(code);
                });
              } else if (data == null && !isLoading) {
                _querySingle(code, forceRefresh: true);
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                children: [
                  // ── Top row: 3-column layout ──
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Col 1: 名称 (flex: 3)
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Text(
                                    data?.fundName ?? '查询中…',
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                                  ),
                                ),
                                if (isLoading)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 1),
                            Text(code, style: const TextStyle(fontSize: 10, color: kTextMuted)),
                          ],
                        ),
                      ),
                      // Col 2: 金额/昨日收益 (flex: 3)
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            GestureDetector(
                              onTap: () => _editAmount(code, amount),
                              child: Text('¥${FundApi.formatAmount(amount)}',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2D3748))),
                            ),
                            const SizedBox(height: 1),
                            Text('$prevEarnSign¥${FundApi.formatAmount(prevEarnings)}',
                                style: TextStyle(fontSize: 11, color: prevEarnColor)),
                          ],
                        ),
                      ),
                      // Col 3: 今日收益率/收益 (flex: 4)
                      Expanded(
                        flex: 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (data != null && data.isEstimated && hasActiveData)
                                  _buildEstimateTag(),
                                if (data != null && hasActiveData) const SizedBox(width: 4),
                                Text(
                                  hasActiveData
                                      ? '${displayChange >= 0 ? '+' : ''}${FundApi.formatTruncated(displayChange, 2)}%'
                                      : '0.00%',
                                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                                      color: hasActiveData ? (displayChange >= 0 ? kRedUp : kGreenDown) : Color(0xFFCBD5E0)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 1),
                            Text(
                              hasActiveData ? '$earnSign¥${FundApi.formatAmount(earnings)}' : '¥0.00',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                  color: hasActiveData ? earnColor : Color(0xFFCBD5E0)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // ── Bottom row: 详细信息 (left) + delete (right) ──
                  Row(
                    children: [
                      // Details toggle (left)
                      InkWell(
                        onTap: () => setState(() => _expanded[code] = !isExpanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('详细信息',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF718096))),
                              const SizedBox(width: 2),
                              Icon(isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                  size: 18, color: Color(0xFF718096)),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Delete button (right)
                      if (!_selectionMode)
                        GestureDetector(
                          onTap: () => _showDeleteConfirm(code),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            child: Container(
                              width: 18, height: 18,
                              decoration: BoxDecoration(color: kTextMuted.withOpacity(0.12), shape: BoxShape.circle),
                              child: Icon(Icons.close, size: 11, color: kTextMuted.withOpacity(0.7)),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (isExpanded && data != null) ...[
                    const SizedBox(height: 8),
                    // Detail info
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Color(0xFFF7FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Previous day change (first in details)
                          Row(children: [
                            Text('上一交易日涨跌幅：',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF718096))),
                            Text(prevChangeText,
                                style: TextStyle(fontSize: 11, color: prevColor, fontWeight: FontWeight.w600)),
                          ]),
                          if (data.nav != null) ...[
                            const SizedBox(height: 4),
                            Row(children: [
                              Text('单位净值：${data.nav}',
                                  style: const TextStyle(fontSize: 11, color: Color(0xFF718096))),
                              const SizedBox(width: 4),
                              Text('(${data.navDate ?? "--"})',
                                  style: const TextStyle(fontSize: 10, color: Color(0xFFA0AEC0))),
                            ]),
                          ],
                          if (data.estimatedNav != null) ...[
                            const SizedBox(height: 4),
                            Text('≈ 预估净值：${FundApi.formatTruncated(data.estimatedNav!, 4)}',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF718096))),
                          ],
                          const SizedBox(height: 4),
                          Row(children: [
                            Text('${data.status}', style: const TextStyle(fontSize: 10, color: Color(0xFFA0AEC0))),
                            const Spacer(),
                            Text('${data.updateTime}', style: const TextStyle(fontSize: 10, color: Color(0xFFA0AEC0))),
                          ]),
                          const SizedBox(height: 6),
                          Text('前十大持仓 (${FundApi.formatTruncated(data.totalPct, 1)}%)',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF4A5568))),
                          const SizedBox(height: 4),
                          if (data.holdings.isEmpty)
                            const Text('暂无持仓数据', style: TextStyle(fontSize: 11, color: Color(0xFFA0AEC0)))
                          else
                            ...data.holdings.asMap().entries.map((e) => _buildStockRow(e.key + 1, e.value)),
                        ],
                      ),
                    ),
                  ],
                  if (isExpanded && data == null && !isLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('暂无数据', style: TextStyle(fontSize: 11, color: Color(0xFFA0AEC0))),
                    ),
                  if (data?.networkError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('⚠ ${data!.networkError}', style: const TextStyle(fontSize: 10, color: Colors.orange)),
                    ),
                ],
              ),
            ),
            ),
          ), // close Container B
          // Separator line
          Container(height: 1, color: const Color(0xFFE2E8F0)),
        ],
      ),
    );
  }

  // ── Widget helpers ──

  Widget _buildEstimateTag() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: kEstimateTagBg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text('预估', style: TextStyle(fontSize: 9, color: kEstimateTagText, fontWeight: FontWeight.bold, height: 1)),
    );
  }

  Widget _buildStockRow(int index, StockHolding s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(children: [
        SizedBox(width: 18, child: Text('$index', style: const TextStyle(fontSize: 11, color: kTextMuted))),
        Expanded(flex: 3, child: Text(s.name, style: const TextStyle(fontSize: 12))),
        Text('${FundApi.formatTruncated(s.pct, 1)}%', style: const TextStyle(fontSize: 11, color: kTextMuted)),
        const SizedBox(width: 6),
        SizedBox(width: 65, child: _buildStockChange(s)),
      ]),
    );
  }

  Widget _buildStockChange(StockHolding s) {
    if (s.change == null) {
      return Tooltip(message: s.errorMsg ?? '失败', child: const Icon(Icons.error_outline, size: 13, color: Colors.orange));
    }
    final color = s.change! >= 0 ? kRedUp : kGreenDown;
    final sign = s.change! >= 0 ? '+' : '';
    return Align(
      alignment: Alignment.centerRight,
      child: Text('$sign${FundApi.formatTruncated(s.change!, 2)}%',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );
  }

  void _showDeleteConfirm(String code) {
    FocusScope.of(context).requestFocus(FocusNode()); // dismiss keyboard
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除基金'),
        content: Text('确定删除基金 $code 吗?'),
        actions: [
          TextButton(onPressed: () { FocusScope.of(ctx).requestFocus(FocusNode()); Navigator.pop(ctx); }, child: const Text('取消')),
          TextButton(onPressed: () { Navigator.pop(ctx); _deleteFund(code); }, child: const Text('确定', style: TextStyle(color: kRedUp))),
        ],
      ),
    );
  }
}