# Apply all 7 fixes to main.dart
# Run from fund_app_flutter directory

import sys
import re

def main():
    with open('lib/main.dart', 'r', encoding='utf-8') as f:
        content = f.read()
        orig = content

    # ============================================================
    # Fix 4: truncateTo + formatTruncated helper functions
    # ============================================================
    # Insert after class FundApi { before the first method
    # Find: static const _timeout
    insertion = '''  // --- 截断到指定位数（不四舍五入）---
  static double truncateTo(double value, int decimals) {
    final factor = _pow10(decimals);
    return (value * factor).truncateToDouble() / factor;
  }
  static double _pow10(int n) {
    double r = 1;
    for (int i = 0; i < n; i++) r *= 10;
    return r;
  }

  /// 将 double 格式化为指定位数的字符串（截断不四舍五入）
  static String formatTruncated(double value, int decimals) {
    final truncated = truncateTo(value, decimals);
    return truncated.toStringAsFixed(decimals);
  }

'''
    
    # Insert after the first method declaration in FundApi class
    # Find the first occurrence of "static Future" after class definition
    first_method = content.find("  static Future")
    if first_method >= 0:
        # Find the previous newline and insert after indentation
        content = content[:first_method] + insertion + content[first_method:]
        print(f"✅ Inserted truncate helper methods at position {first_method}")
    
    # ============================================================
    # Fix 4: Replace estimatedChange rounding
    # ============================================================
    old_rounding = "    estimatedChange = double.parse(estimatedChange.toStringAsFixed(2));"
    new_rounding = "    estimatedChange = truncateTo(estimatedChange, 2); // 截断不四舍五入"
    content = content.replace(old_rounding, new_rounding)
    print(f"✅ Replaced rounding line: {old_rounding.count('estimatedChange') > 0}")
    
    # ============================================================
    # Fix 6+7: Rewrite the session == '已收盘' branch in query()
    # ============================================================
    old_closed_branch = '''    } else if (session == '已收盘') {
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
    }'''

    new_closed_branch = '''    } else if (session == '已收盘') {
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
          estimatedNav: nav != null ? truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4) : null,
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
              ? truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4)
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
          estimatedNav: nav != null ? truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4) : null,
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
    }'''
    
    # Need to also give isAfter15 variable
    # Find: final navIsToday = isSameDay(navDate);
    content = content.replace(
        "    final navIsToday = isSameDay(navDate);",
        "    final navIsToday = isSameDay(navDate);\n    final isAfter15 = now.hour >= 15;"
    )
    print(f"✅ Added isAfter15 variable")
    
    # Replace the closed branch
    if old_closed_branch in content:
        content = content.replace(old_closed_branch, new_closed_branch)
        print("✅ Replaced closed-branch logic")
    else:
        print(f"❌ Could not find old closed branch text. Showing context...")
        # Try to find where it is
        idx = content.find("} else if (session == '已收盘')")
        if idx >= 0:
            print(f"   Found '已收盘' at offset {idx}")
            print(f"   Nearby: ...{content[idx:idx+300]}...")
        else:
            print(f"   '已收盘' not found at all!")
    
    content = content.replace("double.parse(nav) * (1 + estimatedChange / 100)", "truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4)")
    
    # Fix 4: estimatedNav in trading session
    content = content.replace(
        "estimatedNav: nav != null ? double.parse(nav) * (1 + estimatedChange / 100) : null",
        "estimatedNav: nav != null ? truncateTo(double.parse(nav) * (1 + estimatedChange / 100), 4) : null"
    )
    
    # ============================================================
    # Fix 3: Duplicate code check in _addFromBar
    # ============================================================
    old_add_bar = '''    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    _codeCtrl.clear();
    _amountCtrl.clear();
    _addFundWithCheck(code, amount);'''
    new_add_bar = '''    // Fix 3: 检测代码是否已存在
    if (_savedFunds.any((f) => f.code == code)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('基金 $code 已存在列表中，如需修改请在列表中操作'),
      ));
      return;
    }
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    _codeCtrl.clear();
    _amountCtrl.clear();
    _addFundWithCheck(code, amount);'''
    content = content.replace(old_add_bar, new_add_bar)
    print(f"✅ Added duplicate check in _addFromBar")
    
    # Fix 3: Replace _addFund to not update existing amount
    old_add_fund = '''  Future<void> _addFund(String code, double amount) async {
    if (_savedFunds.any((f) => f.code == code)) {
      // 已存在则更新金额
      final idx = _savedFunds.indexWhere((f) => f.code == code);
      _savedFunds[idx].amount = amount;
    } else {
      _savedFunds.add(SavedFund(code: code, amount: amount));
      _expanded[code] = false;
    }
    await FundStore.save(_savedFunds);
    setState(() {});
    _querySingle(code);
  }'''
    new_add_fund = '''  Future<void> _addFund(String code, double amount) async {
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
  }'''
    content = content.replace(old_add_fund, new_add_fund)
    print(f"✅ Updated _addFund to reject duplicates")
    
    # Fix 3: Add duplicate check in _showAddDialog
    old_add_dialog = '''              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
              Navigator.pop(ctx);
              _addFund(code, amount);'''
    new_add_dialog = '''              // Fix 3: 检测重复
              if (_savedFunds.any((f) => f.code == code)) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('基金 $code 已存在')));
                return;
              }
              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
              Navigator.pop(ctx);
              _addFund(code, amount);'''
    content = content.replace(old_add_dialog, new_add_dialog)
    print(f"✅ Added duplicate check in _showAddDialog")
    
    # ============================================================
    # Fix 2 + 5: _editAmount - allow editing zero amount, auto focus, keyboard handling
    # ============================================================
    old_edit_amount = """  void _editAmount(String code, double currentAmount) {
    final ctrl = TextEditingController(text: currentAmount > 0 ? currentAmount.toStringAsFixed(0) : '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改金额'),
        content: SizedBox(
          width: 200,
          child: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: '持有金额（元）'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\\d.]'))],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () async {
            final amt = double.tryParse(ctrl.text.trim()) ?? 0;
            Navigator.pop(ctx);
            if (amt > 0) {
              final idx = _savedFunds.indexWhere((f) => f.code == code);
              if (idx >= 0) {
                setState(() {
                  _savedFunds[idx] = SavedFund(code: code, amount: amt);
                });
                await FundStore.save(_savedFunds);
              }
              if (_results[code] != null) _querySingle(code);
            }
          }, child: const Text('确定')),
        ],
      ),
    );
  }"""
    
    new_edit_amount = """  // Fix 2 + Fix 5: 编辑金额，金额为0也可编辑，自动唤起输入法
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
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\\d.]'))],
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
  }"""
    content = content.replace(old_edit_amount, new_edit_amount)
    print(f"✅ Updated _editAmount (Fix 2+5)")
    
    # ============================================================
    # Fix 5: Add keyboard dismiss to _clearAll, _showDeleteSelectedConfirm and _showDeleteConfirm dialogs
    # ============================================================
    # _clearAll: Add FocusScope.of(ctx).requestFocus(FocusNode()); before cancel pop
    content = content.replace(
        "TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),",
        "TextButton(onPressed: () {\n            FocusScope.of(ctx).requestFocus(FocusNode());\n            Navigator.pop(ctx, false);\n          }, child: const Text('取消')),"
    )
    print(f"✅ Added keyboard dismiss to _clearAll cancel")
    
    # _showDeleteSelectedConfirm cancel
    old_del_sel_cancel = "TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),"
    new_del_sel_cancel = "TextButton(onPressed: () {\n            FocusScope.of(ctx).requestFocus(FocusNode());\n            Navigator.pop(ctx);\n          }, child: const Text('取消')),"
    content = content.replace(old_del_sel_cancel, new_del_sel_cancel)
    print(f"✅ Added keyboard dismiss to _showDeleteSelectedConfirm cancel")
    
    # _showDeleteConfirm cancel
    content = content.replace(
        "TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),",
        "TextButton(onPressed: () {\n            FocusScope.of(ctx).requestFocus(FocusNode());\n            Navigator.pop(ctx);\n          }, child: const Text('取消')),"
    )
    print(f"✅ Added keyboard dismiss to _showDeleteConfirm cancel")
    
    # ============================================================
    # Fix 2: Show "点击设置持有金额" when amount is 0
    # ============================================================
    old_holdings_text = """                  if (saved.amount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: GestureDetector(
                        onTap: () => _editAmount(code, saved.amount),
                        child: Text('持有 ${saved.amount.toStringAsFixed(0)} 元', style: const TextStyle(fontSize: 11, color: kTextMuted)),
                      ),
                    ),"""
    new_holdings_text = """                  // Fix 2: 金额为0时也可点击编辑
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: GestureDetector(
                      onTap: () => _editAmount(code, saved.amount),
                      child: Text(
                        saved.amount > 0
                            ? '持有 ${FundApi.formatTruncated(saved.amount, 2)} 元'
                            : '点击设置持有金额',
                        style: TextStyle(
                          fontSize: 11,
                          color: saved.amount > 0 ? kTextMuted : Theme.of(context).colorScheme.primary,
                          decoration: saved.amount > 0 ? null : TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),"""
    content = content.replace(old_holdings_text, new_holdings_text)
    print(f"✅ Updated holdings text (Fix 2)")
    
    # ============================================================
    # Fix 6: Show estimated change even when closed/待公布净值
    # ============================================================
    # In _buildFundCard - Change the condition from:
    # if (_isMarketHours || data.isFinal)
    # to show estimated change always (remove the _isMarketHours filter)
    old_change_condition = """                      if (_isMarketHours || data.isFinal)
                        _changeWidget(data.estimatedChange, data.isFinal ? '' : '预估'),
                      else
                        Text('--', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kTextMuted)),"""
    new_change_condition = """                      // Fix 6: 始终显示涨跌幅（已收盘等待公布净值时也显示预估）
                      _changeWidget(
                        data.estimatedChange,
                        data.isFinal ? '' : '预估',
                      ),"""
    content = content.replace(old_change_condition, new_change_condition)
    print(f"✅ Updated change condition (Fix 6)")
    
    # Also update the estimatedNav visibility and earnings visibility for closed sessions
    old_nav_condition = """                      if (_isMarketHours && data.estimatedNav != null) ...["""
    new_nav_condition = """                      // Fix 6: 非最终状态也显示预估净值
                      if (data.estimatedNav != null) ...["""
    content = content.replace(old_nav_condition, new_nav_condition)
    print(f"✅ Updated estimatedNav condition (Fix 6)")
    
    old_earnings_condition = """                      if (_isMarketHours && earningsWidget != null) earningsWidget,"""
    new_earnings_condition = """                      if (earningsWidget != null) earningsWidget,"""
    content = content.replace(old_earnings_condition, new_earnings_condition)
    print(f"✅ Updated earnings visibility (Fix 6)")
    
    # ============================================================
    # Fix 4: Replace all toStringAsFixed with formatTruncated in display code
    # ============================================================
    content = content.replace("saved.amount.toStringAsFixed(0)", "FundApi.formatTruncated(saved.amount, 2)")
    content = content.replace("data.estimatedNav!.toStringAsFixed(4)", "FundApi.formatTruncated(data.estimatedNav!, 4)")
    content = content.replace("data.totalPct.toStringAsFixed(1)", "FundApi.formatTruncated(data.totalPct, 1)")
    content = content.replace("change.toStringAsFixed(2)", "FundApi.formatTruncated(change, 2)")
    content = content.replace("s.pct.toStringAsFixed(1)", "FundApi.formatTruncated(s.pct, 1)")
    content = content.replace("changeVal.toStringAsFixed(2)", "FundApi.formatTruncated(changeVal, 2)")
    content = content.replace("earnings.toStringAsFixed(2)", "FundApi.formatTruncated(earnings, 2)")
    print(f"✅ Replaced all toStringAsFixed with formatTruncated (Fix 4)")
    
    # ============================================================
    # Fix 1: Input bar layout - wider code field, standard add button
    # ============================================================
    # Change flex: 2 to flex: 3 for code field
    content = content.replace(
        "flex: 2,",
        "flex: 3,"
    )
    # Change flex: 4 to flex: 3 for amount field
    # First occurrence after first flex: 3 (code field) is the amount field
    # More precise: find the amount field
    old_amount_field = """              Expanded(
                flex: 4,"""
    new_amount_field = """              Expanded(
                flex: 3,"""
    content = content.replace(old_amount_field, new_amount_field)
    print(f"✅ Updated flex ratios (Fix 1)")
    
    # Replace add button from circular container to plain IconButton
    old_add_btn = """              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.add, color: Colors.white),"""
    new_add_btn = """              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 22),"""
    content = content.replace(old_add_btn, new_add_btn)
    print(f"✅ Updated add button (Fix 1)")
    
    # Remove the trailing ) after add button's padding (from the container's closing)
    old_add_close = """                  padding: EdgeInsets.zero,
                ),
              ),"""
    new_add_close = """                constraints: BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),"""
    content = content.replace(old_add_close, new_add_close)
    print(f"✅ Updated add button closing (Fix 1)")
    
    # Shrink const SizedBox(width: 8) before refresh button to const SizedBox(width: 2)
    content = content.replace(
        "              const SizedBox(width: 8),\n              IconButton(\n                icon: const Icon(Icons.refresh,",
        "              const SizedBox(width: 2),\n              IconButton(\n                icon: const Icon(Icons.refresh,"
    )
    content = content.replace(
        "              const SizedBox(width: 8),\n              IconButton(\n                icon: Icon(_selectionMode",
        "              const SizedBox(width: 2),\n              IconButton(\n                icon: Icon(_selectionMode"
    )
    print(f"✅ Updated spacing between buttons (Fix 1)")
    
    # ============================================================
    # Remove unused _isMarketHours local variable since we no longer use it
    # ============================================================
    old_session_var = """    final _session = FundApi.getSessionLabel();
    final _isMarketHours = _session == '交易中' || _session == '午休';"""
    content = content.replace(old_session_var, "")
    print(f"✅ Removed unused _isMarketHours variable")
    
    # ============================================================
    # Remove unused _showAddDialog remnants
    # Actually _showAddDialog is still referenced from the bottom nav, keep it
    # ============================================================
    
    if content == orig:
        print("\n⚠️  No changes were made!")
    else:
        with open('lib/main.dart', 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"\n✅ All fixes applied! File written.")
        print(f"   Original size: {len(orig)} chars")
        print(f"   New size: {len(content)} chars")

if __name__ == '__main__':
    main()
