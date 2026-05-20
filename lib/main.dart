import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
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
      fundData = FundData(
        fundName: fundName, fundCode: fundCode, nav: nav, navDate: navDate,
        estimatedChange: change, estimatedNav: null, actualChange: actualChange,
        isFinal: true, holdings: holdings, totalPct: totalPct,
        updateTime: nowStr, status: '上交易日',
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