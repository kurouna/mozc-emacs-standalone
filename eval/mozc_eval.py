#!/usr/bin/env python3
"""mozc_emacs_helper.exe の変換精度を測る。

mozc.el と同じ S 式で helper を動かし、読みを入れてスペースで変換した結果
（mozc.el で見えるものと同じ）を正解と比べる。helper を差し替えて測れば、
エンジンへのパッチの効果を A/B で比べられる。

  python eval/mozc_eval.py run --helper dist/mozc_emacs_helper.exe \
      --data C:/mozc-build/mozc/src/data/test/quality_regression_test/oss.tsv \
      --out eval/results/base.json
  python eval/mozc_eval.py compare eval/results/base.json eval/results/new.json

データの形式（拡張子と中身で判定）:
  - Mozc の品質回帰テスト TSV（label key value command [rank]）
    Conversion Expected [N] / Not Expected / Match / Not Match だけを使う
  - 読みと正解の TSV（reading<TAB>正解[<TAB>正解...]）
  - AJIMEE-Bench の JSON（input はカタカナ、expected_output は正解のリスト）

学習を汚さないよう、helper は毎回空の一時プロファイル（--profile_dir）で
起動し、変換結果は確定せずに取り消す。標準ライブラリだけで動く。
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# S 式

_DOT = object()


class SExprError(Exception):
    pass


def _tokenize(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c in '()':
            yield c
            i += 1
        elif c == '"':
            buf = []
            i += 1
            while True:
                if i >= n:
                    raise SExprError('unterminated string')
                c = text[i]
                if c == '\\':
                    buf.append(text[i + 1])
                    i += 2
                elif c == '"':
                    i += 1
                    break
                else:
                    buf.append(c)
                    i += 1
            yield ('str', ''.join(buf))
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in '()"':
                j += 1
            atom = text[i:j]
            i = j
            if atom == '.':
                yield _DOT
            else:
                try:
                    yield ('num', int(atom))
                except ValueError:
                    try:
                        yield ('num', float(atom))
                    except ValueError:
                        yield ('sym', atom)


def parse_sexpr(text):
    """S 式を Python のリスト・タプル（ドット対）・アトムにする。"""
    stack = [[]]
    for tok in _tokenize(text):
        if tok == '(':
            stack.append([])
        elif tok == ')':
            if len(stack) < 2:
                raise SExprError('unbalanced )')
            lst = stack.pop()
            if len(lst) == 3 and lst[1] is _DOT:
                lst = (lst[0], lst[2])
            stack[-1].append(lst)
        elif tok is _DOT:
            stack[-1].append(_DOT)
        else:
            kind, val = tok
            stack[-1].append(val if kind != 'sym' else Symbol(val))
    if len(stack) != 1 or len(stack[0]) != 1:
        raise SExprError('incomplete')
    return stack[0][0]


class Symbol(str):
    pass


def to_obj(x):
    """helper の出力（protobuf を alist にしたもの）を dict / list にする。

    フィールドは (key . value)、repeated は (key v1 v2 ...)、メッセージは
    フィールドの並び。"""
    if isinstance(x, tuple):
        return to_obj(x[1])
    if isinstance(x, list):
        if all(isinstance(f, (list, tuple)) and f and isinstance(f[0], Symbol)
               for f in x):
            d = {}
            for f in x:
                if isinstance(f, tuple):
                    d[str(f[0])] = to_obj(f[1])
                else:
                    d[str(f[0])] = [to_obj(e) for e in f[1:]]
            return d
        return [to_obj(e) for e in x]
    if isinstance(x, Symbol):
        return str(x)
    return x


def balanced(text):
    depth, in_str, esc = 0, False, False
    for c in text:
        if in_str:
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
    return depth == 0 and not in_str and text.strip() != ''


# ---------------------------------------------------------------------------
# helper


class HelperError(Exception):
    pass


class Helper:
    def __init__(self, exe, timeout=10.0, args=()):
        self.exe = str(exe)
        self.timeout = timeout
        self.profile = tempfile.mkdtemp(prefix='mozc-eval-')
        self.proc = subprocess.Popen(
            [self.exe, '--suppress_stderr', '--profile_dir', self.profile,
             *args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL)
        self.seq = 0
        greeting = to_obj(self._read())
        self.version = greeting.get('version')
        # 直前のテキストを受け取れる helper は config に set-context を載せる。
        self.set_context = greeting.get('config', {}).get('set-context') == 't'
        self.session = None

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)

    def _read(self):
        timer = threading.Timer(self.timeout, self.proc.kill)
        timer.start()
        try:
            buf = ''
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    raise HelperError('helper exited')
                buf += line.decode('utf-8')
                if balanced(buf):
                    return parse_sexpr(buf)
        finally:
            timer.cancel()

    def call(self, *args):
        self.seq += 1
        seq = self.seq
        line = '(' + ' '.join([str(seq)] + [str(a) for a in args]) + ')\n'
        self.proc.stdin.write(line.encode('utf-8'))
        self.proc.stdin.flush()
        while True:
            resp = to_obj(self._read())
            if 'error' in resp:
                raise HelperError(f"{resp.get('error')}: {resp.get('message')}")
            if resp.get('emacs-event-id') == seq:
                return resp

    def create_session(self):
        self.session = self.call('CreateSession')['emacs-session-id']

    def renew_session(self):
        """直前に確定した文節（変換の文脈）を持たない新しいセッションにする。"""
        self.call('DeleteSession', self.session)
        self.create_session()

    def key(self, *keys):
        return self.call('SendKey', self.session, *keys).get('output', {})

    def context(self, text):
        """カーソルの直前のテキストを渡す（mozc-context.el と同じ）。

        受け取れない helper には送らず False を返す。"""
        if not self.set_context:
            return False
        self.call('SetContext', self.session, quote(text))
        return True


def quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def kata_to_hira(s):
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in s)


def convert(helper, reading, timing=None):
    """読みを入れてスペースで変換し、各文節の上位候補と所要時間を返す。

    返り値: (segments, latency_ms)。segments は
    [{'key': 読み, 'value': 1 位, 'candidates': [{'value', 'segments'}...]}]
    timing に dict を渡すと、最初のキー（文脈を組み立てる）の所要時間を
    'first_key_ms' に入れる。"""
    # mozc.el のかな入力と同じく、キーコードに入力文字列を添えて送る。
    t0 = time.perf_counter()
    helper.key(97, quote(reading))
    if timing is not None:
        timing['first_key_ms'] = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter()
    out = helper.key('space')
    latency = (time.perf_counter() - t0) * 1000
    segs = out.get('preedit', {}).get('segment', [])
    result = [{'key': s.get('key', ''), 'value': s.get('value', ''),
               'candidates': []} for s in segs]
    for i in range(len(result)):
        if i > 0:
            out = helper.key('right')
        words = out.get('all-candidate-words', {}).get('candidates', [])
        result[i]['candidates'] = [
            {'value': w.get('value', ''),
             'segments': w.get('num-segments-in-candidate', 1)}
            for w in words]
    # 確定せずに取り消す（学習させない）。
    for _ in range(4):
        out = helper.key('escape')
        if 'preedit' not in out:
            break
    return result, latency


def get_rank(value, segs, i=0):
    """Mozc の quality_regression_util の GetRank と同じ数え方の順位。

    各文節の候補を前から当てはめ、正解に届くまでに飛ばした候補数の合計。
    届かなければ -1。"""
    if i >= len(segs):
        return 0 if value == '' else -1
    rank = 0
    seen = set()
    for cand in segs[i]['candidates']:
        v = cand['value']
        if v in seen:
            continue
        seen.add(v)
        if not v or not value.startswith(v):
            rank += 1
            continue
        rest = get_rank(value[len(v):], segs, i + cand['segments'])
        if rest == -1:
            rank += 1
            continue
        return rank + rest
    return -1


def find_path(value, segs, i=0):
    """各文節で何番目の候補を選べば value になるか。届かなければ None。

    キー操作（スペースで次の候補、→で次の文節）で選べるよう、1 文節だけの
    候補に限る。"""
    if i >= len(segs):
        return [] if value == '' else None
    for n, cand in enumerate(segs[i]['candidates']):
        v = cand['value']
        if cand['segments'] != 1 or not v or not value.startswith(v):
            continue
        rest = find_path(value[len(v):], segs, i + 1)
        if rest is not None:
            return [n] + rest
    return None


def commit_as(helper, reading, value):
    """読みを変換し、候補を選び直して value として確定する（学習させる）。

    確定できたら True。区切り直しが要るなど、選べないときは取り消して False。"""
    segs, _ = convert(helper, reading)
    path = find_path(value, segs)
    if path is None:
        return False
    helper.key(97, quote(reading))
    out = helper.key('space')
    for i, n in enumerate(path):
        if i > 0:
            out = helper.key('right')
        for _ in range(n):
            out = helper.key('space')
    chosen = ''.join(s.get('value', '')
                     for s in out.get('preedit', {}).get('segment', []))
    if chosen != value:
        for _ in range(4):
            if 'preedit' not in helper.key('escape'):
                break
        return False
    helper.key('enter')
    # 確定した文節が次の変換の文脈にならないよう、セッションを作り直す。
    helper.renew_session()
    return True


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1,
                           prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


# ---------------------------------------------------------------------------
# データ

COMMANDS = ('Conversion Expected', 'Conversion Not Expected',
            'Conversion Match', 'Conversion Not Match')


def load_data(path):
    path = Path(path)
    suite = path.stem
    items, skipped = [], 0
    if path.suffix.lower() == '.json':
        data = json.loads(path.read_text(encoding='utf-8'))
        if isinstance(data, dict):
            data = data.get('items') or data.get('data') or list(data.values())
        for n, d in enumerate(data):
            expected = d['expected_output']
            if isinstance(expected, str):
                expected = [expected]
            items.append({
                'id': f"{suite}:{d.get('index', n)}", 'kind': 'sentence',
                'reading': kata_to_hira(d['input']), 'expected': expected,
                'has_context': bool(d.get('context_text')),
                'context': d.get('context_text') or '',
            })
        return items, skipped
    for n, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        cols = line.split('\t')
        if len(cols) >= 4 and cols[3].startswith('Conversion'):
            command, rank = cols[3].strip(), 0
            m = re.fullmatch(r'Conversion Expected (\d+)', command)
            if m:
                command, rank = 'Conversion Expected', int(m.group(1))
            elif len(cols) >= 5 and cols[4].strip():
                rank = int(cols[4])
            if command not in COMMANDS:
                skipped += 1
                continue
            items.append({'id': f'{suite}:{n}', 'kind': 'rule',
                          'label': cols[0], 'reading': cols[1],
                          'expected': [cols[2]], 'command': command,
                          'rank': rank})
        elif len(cols) >= 4:
            skipped += 1  # Prediction / Suggestion などは対象外
        elif len(cols) >= 2:
            items.append({'id': f'{suite}:{n}', 'kind': 'sentence',
                          'reading': kata_to_hira(cols[0]),
                          'expected': cols[1:], 'has_context': False})
    return items, skipped


def judge_rule(item, top, segs):
    command, value = item['command'], item['expected'][0]
    if command in ('Conversion Match', 'Conversion Not Match'):
        ok = re.fullmatch(value, top) is not None
        return ok if command == 'Conversion Match' else not ok
    rank = get_rank(value, segs)
    ok = 0 <= rank <= item['rank']
    return ok if command == 'Conversion Expected' else not ok


def evaluate(helper, item, send_context=False):
    sent = send_context and helper.context(item.get('context', ''))
    timing = {}
    segs, latency = convert(helper, item['reading'], timing)
    top = ''.join(s['value'] for s in segs)
    r = {'id': item['id'], 'kind': item['kind'], 'reading': item['reading'],
         'expected': item['expected'], 'output': top,
         'segments': [s['value'] for s in segs], 'latency_ms': latency,
         'first_key_ms': timing['first_key_ms'], 'context_sent': sent}
    if item['kind'] == 'rule':
        r['command'] = item['command']
        r['ok'] = judge_rule(item, top, segs)
    else:
        r['has_context'] = item.get('has_context', False)
        r['ok'] = top in item['expected']
        best = min(item['expected'],
                   key=lambda e: edit_distance(top, e) / max(len(e), 1))
        r['edits'] = edit_distance(top, best)
        r['chars'] = len(best)
        ranks = [x for x in (get_rank(e, segs) for e in item['expected'])
                 if x >= 0]
        r['rank'] = min(ranks) if ranks else -1
    return r


# ---------------------------------------------------------------------------
# 集計

def summarize(results):
    lines = []
    by_suite = {}
    for r in results:
        by_suite.setdefault(r['id'].split(':')[0], []).append(r)
    for suite, rs in by_suite.items():
        done = [r for r in rs if 'error' not in r]
        errors = len(rs) - len(done)
        ok = sum(r['ok'] for r in done)
        line = f'{suite}: {ok}/{len(done)} 正解 ({ok / max(len(done), 1):.1%})'
        sent = [r for r in done if r['kind'] == 'sentence']
        if sent:
            edits = sum(r['edits'] for r in sent)
            chars = sum(r['chars'] for r in sent)
            ranks = [r['rank'] for r in sent]
            line += (f', 文字誤り率 {edits / max(chars, 1):.2%}'
                     f', 候補内に正解 {sum(x >= 0 for x in ranks)}/{len(sent)}')
            ctx = [r for r in sent if r.get('has_context')]
            if ctx:
                c_ok = sum(r['ok'] for r in ctx)
                n_ok = sum(r['ok'] for r in sent) - c_ok
                line += (f', 文脈あり {c_ok}/{len(ctx)}'
                         f' / 文脈なし {n_ok}/{len(sent) - len(ctx)}')
        if errors:
            line += f', エラー {errors}'
        lines.append(line)
    for key, name in (('latency_ms', '変換時間'),
                      ('first_key_ms', '最初のキーの処理時間')):
        lat = sorted(r[key] for r in results if key in r)
        if lat:
            p95 = lat[min(len(lat) - 1, int(len(lat) * 0.95))]
            lines.append(f'{name}: 中央値 {statistics.median(lat):.1f}ms'
                         f' / 95% {p95:.1f}ms / 最大 {lat[-1]:.1f}ms')
    sent = sum(bool(r.get('context_sent')) for r in results)
    if sent:
        lines.append(f'直前のテキストを渡した項目: {sent}')
    return '\n'.join(lines)


def cmd_move(args):
    """前の項目を確定してからカーソルを動かし、別の場所で変換する。

    確定した文節は次の変換の文脈になる。カーソルを動かしたあとも残って
    いると、関係のない文脈で変換することになる。各項目の前に、ひとつ前の
    項目を 1 位のまま確定し、カーソル移動のキー（--move-key）を送る。"""
    items = []
    for path in args.data:
        its, _ = load_data(path)
        items += its
    if args.limit:
        items = items[:args.limit]
    exe = Path(args.helper)
    helper = Helper(exe, timeout=args.timeout, args=args.helper_arg)
    results = []
    try:
        helper.create_session()
        for n, item in enumerate(items):
            helper.renew_session()
            helper.key(97, quote(items[n - 1]['reading']))
            helper.key('space')
            helper.key('enter')
            moved = helper.key(args.move_key)
            r = evaluate(helper, item, args.send_context)
            r['move_consumed'] = moved.get('consumed') == 't'
            results.append(r)
        version = helper.version
    finally:
        helper.close()
    print(f'helper: {exe} {" ".join(args.helper_arg)} ({version})')
    print(summarize(results))
    consumed = sum(r['move_consumed'] for r in results)
    if consumed:
        print(f'注意: {args.move_key} を Mozc が処理した項目 {consumed}')
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(
            {'meta': {'helper': str(exe.resolve()),
                      'helper_args': args.helper_arg,
                      'helper_version': version, 'move_key': args.move_key,
                      'data': [str(Path(p).resolve()) for p in args.data],
                      'time': time.strftime('%Y-%m-%dT%H:%M:%S')},
             'results': results}, ensure_ascii=False, indent=1),
            encoding='utf-8')


def cmd_run(args):
    items, skipped = [], 0
    for path in args.data:
        its, sk = load_data(path)
        items += its
        skipped += sk
    if args.limit:
        items = items[:args.limit]
    exe = Path(args.helper)
    helper = Helper(exe, timeout=args.timeout, args=args.helper_arg)
    helper.create_session()
    results = []
    try:
        for n, item in enumerate(items, 1):
            try:
                results.append(evaluate(helper, item, args.send_context))
            except HelperError as e:
                results.append({'id': item['id'], 'kind': item['kind'],
                                'reading': item['reading'], 'error': str(e),
                                'ok': False})
                helper.close()
                helper = Helper(exe, timeout=args.timeout, args=args.helper_arg)
                helper.create_session()
            if n % 50 == 0:
                print(f'{n}/{len(items)}', file=sys.stderr)
        version = helper.version
    finally:
        helper.close()
    meta = {
        'helper': str(exe.resolve()),
        'helper_sha256': hashlib.sha256(exe.read_bytes()).hexdigest(),
        'helper_version': version,
        'data': [str(Path(p).resolve()) for p in args.data],
        'skipped': skipped,
        'time': time.strftime('%Y-%m-%dT%H:%M:%S'),
    }
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({'meta': meta, 'results': results},
                                  ensure_ascii=False, indent=1),
                       encoding='utf-8')
    print(summarize(results))
    if skipped:
        print(f'対象外（予測・サジェストの項目）: {skipped}')
    if args.show_errors:
        for r in results:
            if not r['ok']:
                print(f"NG {r['id']}\t{r['reading']}\t{r.get('output', r.get('error'))}"
                      f"\t期待: {' | '.join(r.get('expected', []))}")


def cmd_learn(args):
    """学習させてから変換し直し、学習の効果と副作用を測る。

    文の項目を交互に「学習用」と「対照用」に分け、次の順に測る。
      1. 学習前: 学習用の項目の読み、その前後に別の読みを付けた入力、対照用の項目
      2. 学習: 学習用の項目を正解の候補を選んで確定する（1 項目 1 回）
      3. 学習後: 1 と同じ入力
    前後に別の読みを付けた入力は、文節の区切りが学習時と変わっても学習が
    効くかを見るもの（正解が出力の末尾・先頭にそのまま含まれれば正解）。"""
    items = []
    for path in args.data:
        its, _ = load_data(path)
        items += [it for it in its if it['kind'] == 'sentence']
    if args.limit:
        items = items[:args.limit]
    train, hold = items[0::2], items[1::2]
    fillers = [it['reading'] for it in hold]

    def tests():
        for n, it in enumerate(train):
            filler = fillers[n % len(fillers)]
            yield ('same', it, it['reading'], lambda o, e: o in e)
            yield ('after', it, filler + it['reading'],
                   lambda o, e: any(o.endswith(x) for x in e))
            yield ('before', it, it['reading'] + filler,
                   lambda o, e: any(o.startswith(x) for x in e))
        for it in hold:
            yield ('holdout', it, it['reading'], lambda o, e: o in e)

    def measure(helper, learned):
        res = {}
        for kind, it, reading, ok in tests():
            if kind != 'holdout' and it['id'] not in learned:
                continue
            segs, latency = convert(helper, reading)
            out = ''.join(s['value'] for s in segs)
            res[(kind, it['id'])] = {'output': out, 'latency_ms': latency,
                                     'ok': ok(out, it['expected'])}
        return res

    exe = Path(args.helper)
    helper = Helper(exe, timeout=args.timeout, args=args.helper_arg)
    try:
        helper.create_session()
        # 学習できる項目（正解を候補から選べるもの）を先に決める。
        learned = {}
        for it in train:
            segs, _ = convert(helper, it['reading'])
            for e in it['expected']:
                if find_path(e, segs) is not None:
                    learned[it['id']] = e
                    break
        before = measure(helper, learned)
        failed = 0
        for it in train:
            if it['id'] in learned and not commit_as(
                    helper, it['reading'], learned[it['id']]):
                failed += 1
                del learned[it['id']]
        after = measure(helper, learned)
        version = helper.version
    finally:
        helper.close()

    names = {'same': '同じ読みで再変換', 'after': '前に別の読みを付けて変換',
             'before': '後ろに別の読みを付けて変換',
             'holdout': '学習していない項目（副作用）'}
    lines = [f'helper: {exe} {" ".join(args.helper_arg)} ({version})',
             f'学習: {len(learned)}/{len(train)} 項目を確定'
             f'（候補から選べず学習できなかった {len(train) - len(learned)}'
             f'{f"、うち確定に失敗 {failed}" if failed else ""}）']
    rows = []
    for kind in ('same', 'after', 'before', 'holdout'):
        keys = [k for k in after if k[0] == kind]
        b = sum(before[k]['ok'] for k in keys if k in before)
        a = sum(after[k]['ok'] for k in keys)
        gained = sum(after[k]['ok'] and not before[k]['ok'] for k in keys)
        lost = sum(before[k]['ok'] and not after[k]['ok'] for k in keys)
        lines.append(f'{names[kind]}: {b}/{len(keys)} → {a}/{len(keys)}'
                     f'（改善 {gained}、悪化 {lost}）')
        for k in keys:
            rows.append({'test': kind, 'id': k[1],
                         'before': before[k], 'after': after[k]})
    lat = sorted(v['latency_ms'] for v in after.values())
    if lat:
        lines.append(f'学習後の変換時間: 中央値 {statistics.median(lat):.1f}ms'
                     f' / 最大 {lat[-1]:.1f}ms')
    print('\n'.join(lines))
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(
            {'meta': {'helper': str(exe.resolve()),
                      'helper_args': args.helper_arg,
                      'helper_version': version,
                      'data': [str(Path(p).resolve()) for p in args.data],
                      'learned': learned,
                      'time': time.strftime('%Y-%m-%dT%H:%M:%S')},
             'summary': lines, 'results': rows},
            ensure_ascii=False, indent=1), encoding='utf-8')
    if args.show_errors:
        for r in rows:
            if r['before']['ok'] != r['after']['ok']:
                mark = '改善' if r['after']['ok'] else '悪化'
                print(f"{mark} {r['test']} {r['id']}\n"
                      f"  前: {r['before']['output']}\n"
                      f"  後: {r['after']['output']}")


def cmd_compare(args):
    a = json.loads(Path(args.base).read_text(encoding='utf-8'))
    b = json.loads(Path(args.new).read_text(encoding='utf-8'))
    print('== 基準:', a['meta']['helper'], a['meta']['helper_version'])
    print(summarize(a['results']))
    print('== 比較:', b['meta']['helper'], b['meta']['helper_version'])
    print(summarize(b['results']))
    base = {r['id']: r for r in a['results']}
    better, worse = [], []
    for r in b['results']:
        o = base.get(r['id'])
        if o is None or r.get('output') == o.get('output'):
            continue
        if r['ok'] and not o['ok']:
            better.append((o, r))
        elif o['ok'] and not r['ok']:
            worse.append((o, r))
        elif r['kind'] == 'sentence' and 'edits' in r and 'edits' in o:
            (better if r['edits'] < o['edits'] else worse).append((o, r))
    for title, pairs in (('改善', better), ('悪化', worse)):
        print(f'== {title}: {len(pairs)}')
        for o, r in pairs:
            print(f"{r['id']}\t{r['reading']}\n  前: {o.get('output')}\n"
                  f"  後: {r.get('output')}\n  正解: {' | '.join(r['expected'])}")


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run', help='helper で変換して正解と比べる')
    r.add_argument('--helper', required=True, help='mozc_emacs_helper.exe')
    r.add_argument('--data', required=True, action='append',
                   help='評価データ（複数指定可）')
    r.add_argument('--out', help='結果の JSON')
    r.add_argument('--limit', type=int, help='先頭から N 件だけ')
    r.add_argument('--timeout', type=float, default=10.0,
                   help='helper の応答待ち（秒）')
    r.add_argument('--show-errors', action='store_true',
                   help='不正解の項目を表示する')
    r.set_defaults(func=cmd_run)
    l = sub.add_parser('learn', help='学習させてから変換し直す')
    l.add_argument('--helper', required=True, help='mozc_emacs_helper.exe')
    l.add_argument('--data', required=True, action='append',
                   help='評価データ（文の項目だけを使う。複数指定可）')
    l.add_argument('--out', help='結果の JSON')
    l.add_argument('--limit', type=int, help='先頭から N 件だけ')
    l.add_argument('--timeout', type=float, default=10.0,
                   help='helper の応答待ち（秒）')
    l.add_argument('--show-errors', action='store_true',
                   help='学習の前後で結果が変わった項目を表示する')
    l.set_defaults(func=cmd_learn)
    m = sub.add_parser('move', help='確定してからカーソルを動かして変換する')
    m.add_argument('--helper', required=True, help='mozc_emacs_helper.exe')
    m.add_argument('--data', required=True, action='append',
                   help='評価データ（複数指定可）')
    m.add_argument('--out', help='結果の JSON')
    m.add_argument('--limit', type=int, help='先頭から N 件だけ')
    m.add_argument('--timeout', type=float, default=10.0,
                   help='helper の応答待ち（秒）')
    m.add_argument('--move-key', default='left',
                   help='カーソル移動として送るキー（既定: left）')
    m.set_defaults(func=cmd_move)
    for sp in (r, m):
        sp.add_argument('--send-context', action='store_true',
                        help='直前のテキスト（AJIMEE-Bench の context_text）を'
                             'helper に渡す（受け取れる helper だけ）')
    for sp in (r, l, m):
        sp.add_argument('--helper-arg', action='append', default=[],
                        help='helper に渡す引数（例: --helper-arg=--foo）')
    c = sub.add_parser('compare', help='2 つの結果を比べる')
    c.add_argument('base')
    c.add_argument('new')
    c.set_defaults(func=cmd_compare)
    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
