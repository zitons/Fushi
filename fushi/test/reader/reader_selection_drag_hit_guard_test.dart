// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——那里删掉
// 模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// 移动端 EPUB 文本选择「坐标 -> 文本位置」解析层守卫。
///
/// 症状（用户报）：长按进入选择、拖选/拖手柄时，手指落在**字缝、行尾、行首、行距、段间空白**
/// 上（没有字符矩形盖住手指），手柄停止移动，松手再拖也过不去。
///
/// 根因：拖动路径只认 `getSelectableCharacterAtPoint`（要求手指压在字符矩形上，精确或 ±6px），
/// 落空后 `updateRangeSelection` 把端点钉回锚点（选区塌回锚点字）、`moveSelectionHandle`
/// 直接 return（手柄冻结）。修法不是把 ±6px 调大，而是补一层真正的坐标解析：
///   ① 原生 caret API（`caretPositionFromPoint` / `caretRangeFromPoint`）——Chrome WebView 与
///      WKWebView 都实现「最近 caret」clamp 语义；
///   ② 拿不到 / 被手柄遮挡 / 结果不可见时的几何兜底：在命中元素所在文本块里按「交叉轴最近
///      -> 行内轴最近」逐字符扫描（与布局引擎 `getOffsetForHorizontal` 同一判据）；
///   ③ 端点规范化 + 单词/字符粒度吸附 + BUG-1797 可见性收口。
///
/// 真机触屏 WebView 的真手势只能设备验；**几何行为**由
/// `reader_selection_drag_hit_behavior_test.dart`（Node 真跑生产 JS + fake DOM 回放拖动
/// 坐标）守，这里只钉源码契约（API 存在、优先级顺序、无原生选区）。
String _between(String src, String startMarker, String endMarker) {
  final int start = src.indexOf(startMarker);
  final int end = src.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
  expect(end, greaterThan(start), reason: '找不到 $endMarker（在 $startMarker 之后）');
  return src.substring(start, end);
}

void main() {
  final String js = ReaderSelectionScripts.source();
  // 解析层所在区间（插在几何命中层 getSelectableCharacterAtPoint 与句子解析之间）。
  final String layer = _between(
    js,
    'charRangeAt: function',
    'getSentenceContext: function',
  );

  group('① 坐标 -> 文本位置解析层存在且优先级正确', () {
    test('三级 API 齐全（端点解析入口 / 原生 caret / 几何兜底）', () {
      for (final String api in <String>[
        'resolveSelectionEndpoint: function',
        'caretPositionAtPoint: function',
        'nativeCaretAtPoint: function',
        'geometricCaretAtPoint: function',
        'charRangeAt: function',
        'charAxisBounds: function',
        'normalizeEndpoint: function',
        'caretHasVisibleNeighbour: function',
        'compareTextPosition: function',
        'spaceDelimitedWordBounds: function',
        'snapEndpointToWord: function',
        'selectionAnchorAtHit: function',
      ]) {
        expect(js, contains(api), reason: '缺解析层 API：$api');
      }
    });

    test('优先原生 caret API，两条 WebView 方言都覆盖', () {
      final String body = _between(
        js,
        'nativeCaretAtPoint: function',
        'geometricCaretAtPoint: function',
      );
      expect(body, contains('document.caretPositionFromPoint'),
          reason: 'Chromium/Android WebView 的 caretPositionFromPoint');
      expect(body, contains('document.caretRangeFromPoint'),
          reason: 'WKWebView / 老 Blink 的 caretRangeFromPoint');
      // BUG-765：手柄 div / documentElement 的命中不可信，只认文本节点结果。
      expect(body, contains('Node.TEXT_NODE'));
      // BUG-1797：分页页边距带里被 clip 掉的相邻页字符不得成为端点。
      expect(body, contains('caretHasVisibleNeighbour'));
      final String driver = _between(
        js,
        'caretPositionAtPoint: function',
        'resolveSelectionEndpoint: function',
      );
      final int nativeIdx = driver.indexOf('nativeCaretAtPoint');
      final int geometricIdx = driver.indexOf('geometricCaretAtPoint');
      expect(nativeIdx, greaterThanOrEqualTo(0));
      expect(geometricIdx, greaterThan(nativeIdx),
          reason: '原生快路失败后必须可达几何兜底（不是早退）');
    });

    test('几何兜底按「交叉轴 -> 行内轴」定行/定 caret（与布局引擎同判据）', () {
      final String body = _between(
        js,
        'geometricCaretAtPoint: function',
        'caretPositionAtPoint: function',
      );
      // 交叉轴（横排 y / 竖排 x）先定行 —— 否则拖到行尾右侧时端点会跳到下一行。
      expect(body, contains('crossDist'), reason: '缺交叉轴距离');
      expect(body, contains('inlineDist'), reason: '缺行内轴距离');
      final int crossIdx = body.indexOf('crossCoord < bounds.crossLo');
      expect(crossIdx, greaterThanOrEqualTo(0), reason: '交叉轴距离必须按行盒上下沿算');
      // 行内轴按字符矩形中点取前沿/后沿（Layout.getOffsetForHorizontal）——行尾右侧空白
      // clamp 到行尾、行首左侧空白 clamp 到行首。
      expect(
        body,
        contains('afterGlyph'),
        reason: '缺「点越过字符中线取后沿」的前沿/后沿规则',
      );
      // 有界：根是命中元素所在的块（不落整个 body），且有字符数上限。
      expect(body, contains('elementFromPoint'));
      expect(body, contains('closest('));
      expect(body, contains('scanned <'), reason: '逐字符扫描必须有上界（防超大块卡住拖动帧）');
      // 可见性收口：不可见字符不参与竞争（BUG-1797）。
      expect(body, contains('charRangeVisible'));
    });

    test('端点规范化：跳过的纯空白/振假名节点必须挪到正文节点', () {
      final String body = _between(
        js,
        'normalizeEndpoint: function',
        'caretHasVisibleNeighbour: function',
      );
      // collectRangeBetween 的游走用 createWalker（REJECT 纯空白节点与振假名），端点落在被跳过
      // 的节点里时游走永远匹配不到 endNode —— 会一路扫到文末、选区暴涨。故必须先规范化。
      expect(body, contains('createWalker'));
      expect(body, contains('isFurigana'));
      expect(
        body,
        contains(r'/^[\s　]*$/'),
        reason: '纯空白文本节点判据必须与 createWalker 的 REJECT 判据一致',
      );
      expect(body, contains('walker.nextNode()'), reason: '正向顺延到下一个正文节点');
      expect(body, contains('previousNode()'), reason: '反向回退到上一个正文节点');
    });

    test('端点解析：严格命中优先（零回归）+ 落空才走坐标解析 + 端点必须可见', () {
      final String body = _between(
        js,
        'resolveSelectionEndpoint: function',
        'selectionAnchorAtHit: function',
      );
      expect(body, contains('if (strictHit)'), reason: '手指压在字符矩形上时必须沿用严格命中结果');
      expect(body, contains('this.caretPositionAtPoint('));
      // caret 是字符之间的位置：正向取 caret 前一个字符、反向取 caret 所在字符。
      expect(body, contains('this.charBefore(caret.node, caret.offset)'));
      expect(body, contains('this.charAt(caret.node, caret.offset)'));
      // BUG-1797：端点字符必须可见，否则页边距带里的相邻页字符会被选中。
      expect(body, contains('charRangeVisible'), reason: '端点可见性收口（BUG-1797）');
      expect(body, contains('return null'), reason: '解析失败要交给调用方保持旧端点');
    });
  });

  group('② 单词选择模式（Android 手柄拖动语义）', () {
    test('空格分词词的边界用与扫描模型同一套真值', () {
      final String body = _between(
        js,
        'spaceDelimitedWordBounds: function',
        'snapEndpointToWord: function',
      );
      // BUG-2056 的字母集/词内撇号判据 —— 不另造一套「什么算单词」的定义。
      expect(body, contains('isSpaceDelimitedLetter'));
      expect(body, contains('isIntraWordApostrophe'));
    });

    test('吸附只在单词选择模式下生效（CJK 自动保持字符级）', () {
      final String body = _between(
        js,
        'snapEndpointToWord: function',
        'normalizeEndpoint: function',
      );
      expect(
        body,
        contains('if (!this.wordSelectMode'),
        reason: '单词选择模式开关必须前置，否则单击查词/字符级选择会被改成词选择',
      );
      expect(body, contains('bounds.end - 1'), reason: '正向取词末字符（端点字符计入区间）');
      expect(body, contains('bounds.start'), reason: '反向取词首字符');
      // CJK 不在空格分词词里 -> 原样返回，保持字符级（词典引擎按字符扫描）。
      expect(
        body,
        contains('if (!bounds) return endpoint;'),
        reason: 'CJK / 标点 / 空白必须原样返回（不退化成词选择）',
      );
    });

    test('wordSelectMode 只在长按建立、选区清掉即复位', () {
      final String begin = _between(
        js,
        'beginRangeSelection: function',
        'updateRangeSelection: function',
      );
      expect(begin, contains('this.wordSelectMode = true'));
      final String clear = js.substring(js.indexOf('clearSelection: function'));
      expect(
        clear,
        contains('this.wordSelectMode = false'),
        reason: '会话状态必须复位，否则下一次单击查词会继承词选择模式',
      );
      expect(clear, contains('this.dragAnchor = null'));
    });

    test('长按锚点是区间（词首..词末 / 单字），反向拖动不丢词尾', () {
      final String body = _between(
        js,
        'selectionAnchorAtHit: function',
        'getSentenceContext: function',
      );
      expect(body, contains('spaceDelimitedWordBounds'));
      expect(body, contains('offset: bounds.start'));
      expect(body, contains('endOffset: bounds.end - 1'));
      // 非空格分词脚本（CJK / 标点 / 空白）：单字锚点，首尾同一位置。
      expect(body, contains('offset: hit.offset, endNode: hit.node, endOffset: hit.offset'));
    });
  });

  group('③ 未破坏既有约束', () {
    test('解析层绝不触碰原生选区（不复活 TODO-1279 双选区）', () {
      expect(layer, isNot(contains('window.getSelection')), reason: '解析层不读原生选区');
      expect(layer, isNot(contains('.addRange(')), reason: '解析层不写原生选区');
      expect(layer, isNot(contains('removeAllRanges')), reason: '解析层不动原生选区');
    });

    test('查词命中分层未被改动（查词仍剔除词边界）', () {
      final String body = _between(
        js,
        'getCharacterAtPoint: function',
        'getSelectableCharacterAtPoint: function',
      );
      expect(body, contains('isScanBoundary'));
      expect(body, contains('this.getSelectableCharacterAtPoint(x, y)'));
    });

    test('桌面鼠标路径不经解析层（只被拖动入口调用）', () {
      // 调用点只应有 3 处、全在拖选/拖手柄入口里：updateRangeSelection 的正向与反向各一次、
      // moveSelectionHandle 一次。桌面鼠标走浏览器原生选区 + 右键菜单，单击查词走 selectText
      // （`pointer: fine` 分支），都不该碰这一层。
      final int calls = 'this.resolveSelectionEndpoint('.allMatches(js).length;
      final int definitions = 'resolveSelectionEndpoint: function'.allMatches(js).length;
      expect(definitions, 1);
      expect(
        calls,
        lessThanOrEqualTo(4),
        reason: '解析层只应由拖动入口调用；调用点变多说明有别的路径被牵动',
      );
      final String tap = _between(
        js,
        'selectText: function',
        'selectFromPosition: function',
      );
      expect(tap, isNot(contains('resolveSelectionEndpoint')),
          reason: '单击查词路径不得经解析层（桌面/移动点词行为零变化）');
      expect(tap, isNot(contains('wordSelectMode')));
    });
  });
}
