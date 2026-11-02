#!/usr/bin/env python3
# Copyright 2026, elecxzy project
# Use of this source code is governed by the BSD 3-Clause license in LICENSE.
"""Tiny Bazel-subset evaluator for the Mozc tree.

Evaluates Mozc's BUILD.bazel files as Python with stub rule functions,
resolves select() for an OSS Windows build with MinGW gcc, and writes a
build.ninja that builds the requested targets (including the genrules that
generate the dictionary data) without Bazel.

usage:
  mini_bazel.py --src MOZC/src --out OUT --prefix PREFIX --wil WIL/include \
      --compat COMPAT --external EXTERNAL //emacs_standalone:mozc_emacs_helper

Run ninja in OUT with PYTHONPATH=MOZC/src.  Only the subset of Bazel that the
Mozc engine and its data generators use is supported.
"""
import argparse
import builtins
import glob as _glob
import os
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument('--src', required=True, help='Mozc src/ directory')
ap.add_argument('--out', required=True, help='build directory')
ap.add_argument('--prefix', required=True, help='abseil/protobuf install')
ap.add_argument('--wil', required=True, help='WIL include directory')
ap.add_argument('--compat', required=True, help='MinGW compat headers')
ap.add_argument('--external', required=True,
                help='directory holding @repo/FILE for external file labels')
ap.add_argument('targets', nargs='+')
ARGS = ap.parse_args()


def _abs(p):
  return os.path.abspath(p).replace(os.sep, '/')


SRC = _abs(ARGS.src)
OUT = _abs(ARGS.out)
PREFIX = _abs(ARGS.prefix)
EXT = _abs(ARGS.external)
# ninja runs in OUT; relative paths keep drive letters ("C:") out of the
# "name:align:path" arguments of dataset_writer_main.
RELSRC = os.path.relpath(SRC, OUT).replace(os.sep, '/')

# Conditions considered true.  Order matters: earlier keys win.
TRUE_CONDITIONS = [
    '//bazel/cc_target_os:oss_windows',
    '@platforms//os:windows',
    '//:compiler_gcc_like',
]

# Targets whose sources cannot be built with MinGW are replaced, or get
# extra sources, from the emacs_standalone overlay package.
SRC_OVERRIDES = {
    '//base/win32:win_sandbox': ['//emacs_standalone:win_sandbox_mingw.cc'],
}
EXTRA_SRCS = {
    '//base/win32:win_util': ['//emacs_standalone:aux_ulib_mingw.cc'],
}

targets = {}  # label -> dict


# ---- Starlark emulation ----------------------------------------------------

class Struct:
  def __init__(self, **kw):
    self.__dict__.update(kw)


class Select:
  def __init__(self, d):
    self.d = d


class SelList:
  """Lazy concatenation of lists and selects (list + select(...))."""

  def __init__(self, parts):
    self.parts = parts

  def __add__(self, o):
    return SelList(self.parts + [o])

  def __radd__(self, o):
    return SelList([o] + self.parts)


def resolve(v):
  if isinstance(v, Select):
    for k in TRUE_CONDITIONS:
      if k in v.d:
        return resolve(v.d[k])
    return resolve(v.d.get('//conditions:default', []))
  if isinstance(v, SelList):
    out = []
    for p in v.parts:
      r = resolve(p)
      out = out + r if isinstance(r, list) else r
    return out
  return v


def select(d, no_match_error=None):
  return SelList([Select(d)])


class Ctx:
  pkg = ''


CTX = Ctx()


def label_of(name, pkg=None):
  pkg = CTX.pkg if pkg is None else pkg
  if name.startswith('@@'):
    name = name[1:]
  if name.startswith('@'):
    repo, _, rest = name.partition('//')
    if not rest:
      return name + '//:' + repo[1:]
    if ':' not in rest:
      rest = rest + ':' + rest.split('/')[-1]
    return repo + '//' + rest
  if name.startswith('//'):
    rest = name[2:]
    if ':' not in rest:
      rest = rest + ':' + rest.split('/')[-1]
    return '//' + rest
  if name.startswith(':'):
    name = name[1:]
  return '//' + pkg + ':' + name


def add_target(kind, **kw):
  name = kw.get('name')
  if name is None:
    return
  lab = '//' + CTX.pkg + ':' + name
  kw.update(kind=kind, pkg=CTX.pkg, label=lab)
  targets[lab] = kw


def make_rule(kind):
  def f(*a, **kw):
    add_target(kind, **kw)
  return f


def glob(include, exclude=[], allow_empty=True, **kw):
  base = os.path.join(SRC, CTX.pkg)
  res = set()
  for pat in include:
    for p in _glob.glob(os.path.join(base, pat), recursive=True):
      if os.path.isfile(p):
        res.add(os.path.relpath(p, base).replace(os.sep, '/'))
  for pat in exclude:
    for p in _glob.glob(os.path.join(base, pat), recursive=True):
      res.discard(os.path.relpath(p, base).replace(os.sep, '/'))
  return sorted(res)


def _noop(*a, **kw):
  return None


class Native:
  def __getattr__(self, n):
    if n == 'package_name':
      return lambda: CTX.pkg
    if n == 'package_relative_label':
      return label_of
    if n == 'glob':
      return glob
    return make_rule(n)


# ---- stubs for Mozc macros (build_defs.bzl and friends) --------------------

def mozc_cc_library(deps=[], copts=[], **kw):
  add_target('cc_library', deps=SelList([deps, ['//:macro']]),
             copts=SelList([copts, ['-funsigned-char']]), **kw)


def mozc_cc_binary(deps=[], copts=[], linkopts=[], **kw):
  kw.pop('enable_win32_default_manifest', None)
  add_target('cc_binary', deps=SelList([deps, ['//:macro']]),
             copts=SelList([copts, ['-funsigned-char']]), linkopts=linkopts,
             **kw)


def mozc_py_binary(name, srcs, **kw):
  add_target('py_binary', name=name, srcs=srcs, main=kw.get('main'))


def mozc_select(default=[], client=None, oss=None, windows=None,
                oss_windows=None, **kw):
  for v in (oss_windows, oss, windows, client):
    if v is not None:
      return v
  return default


def mozc_run_build_tool(name, tool, outs, args=[], env={}, srcs={},
                        positional_srcs=[], **kw):
  add_target('run_build_tool', name=name, tool=tool, outs_map=outs, args=args,
             srcs_map=srcs, positional_srcs=positional_srcs)


def mozc_embed_file(name, srcs, out, var_name, as_string_view=False,
                    skip_until=None, **kw):
  args = ['--name=' + var_name]
  if as_string_view:
    args.append('--as_string_view')
  if skip_until:
    args.append('--skip_until=' + skip_until)
  mozc_run_build_tool(name=name, srcs={'--input': srcs}, args=args,
                      outs={'--output': out}, tool='//build_tools:embed_file')


def cc_proto_library(name, deps, **kw):
  add_target('cc_proto_library', name=name, deps=deps)


def run_binary(name, tool, outs, srcs=[], args=[], **kw):
  add_target('run_binary', name=name, tool=tool, outs=outs, srcs=srcs,
             args=args)


BASE_ENV = {
    'select': select, 'glob': glob, 'struct': Struct, 'native': Native(),
    'Label': label_of, 'package': _noop, 'licenses': _noop,
    'exports_files': _noop, 'package_group': _noop,
    'register_extension_info': _noop, 'config_setting': _noop,
    'cc_library': make_rule('cc_library'), 'cc_binary': make_rule('cc_binary'),
    'genrule': make_rule('genrule'), 'filegroup': make_rule('filegroup'),
    'alias': make_rule('alias'), 'proto_library': make_rule('proto_library'),
    'cc_proto_library': cc_proto_library,
    'mozc_cc_library': mozc_cc_library, 'mozc_cc_binary': mozc_cc_binary,
    'mozc_py_binary': mozc_py_binary,
    'mozc_py_library': make_rule('py_library'),
    'mozc_select': mozc_select, 'mozc_run_build_tool': mozc_run_build_tool,
    'mozc_embed_file': mozc_embed_file, 'run_binary': run_binary,
    'mozc_select_enable_session_watchdog': lambda on=[], off=[]: off,
    'mozc_select_enable_supplemental_model': lambda on=[], off=[]: off,
    'mozc_select_enable_usage_rewriter': lambda on=[], off=[]: on,
    'mozc_select_release_channel': lambda dev=[], stable=[]: stable,
    'MOZC_TAGS': Struct(ANDROID_ONLY=[], LINUX_ONLY=[], MAC_ONLY=[],
                        WIN_ONLY=[]),
    'selects': Struct(config_setting_group=_noop),
    'mozc_cc_test': _noop, 'py_test': _noop,
}

# .bzl files evaluated for real; every other load() gets stubs.
REAL_BZL = {'//:config.bzl', '//data_manager:mozc_data.bzl'}
bzl_cache = {}


class Namespace(dict):
  """BUILD file namespace: unknown names become no-op rules."""

  def __missing__(self, k):
    if hasattr(builtins, k):
      return getattr(builtins, k)
    return make_rule(k)


def load_bzl(lab):
  if lab not in bzl_cache:
    env = None
    if lab in REAL_BZL:
      pkg, _, f = lab[2:].partition(':')
      path = os.path.join(SRC, pkg, f)
      env = dict(BASE_ENV)
      env['load'] = make_load(env)
      exec(compile(open(path, encoding='utf-8').read(), path, 'exec'), env)
    bzl_cache[lab] = env
  return bzl_cache[lab]


def make_load(env):
  def load(lab, *names, **aliases):
    mod = load_bzl(label_of(lab))
    for local, n in [(n, n) for n in names] + list(aliases.items()):
      if mod is not None and n in mod:
        env[local] = mod[n]
      elif n in BASE_ENV:
        env[local] = BASE_ENV[n]
      elif n[:1].isupper():
        env[local] = Struct()
      else:
        env[local] = make_rule(n)
  return load


def eval_build(pkg):
  path = os.path.join(SRC, pkg, 'BUILD.bazel')
  if not os.path.exists(path):
    return
  CTX.pkg = pkg
  env = Namespace(BASE_ENV)
  env['load'] = make_load(env)
  # Module-level names go through the mapping, so __missing__ applies.
  exec(compile(open(path, encoding='utf-8').read(), path, 'exec'),
       {'__builtins__': builtins}, env)


loaded_pkgs = set()


def get(lab):
  if lab.startswith('@'):
    return None
  pkg = lab[2:].partition(':')[0]
  if pkg not in loaded_pkgs:
    loaded_pkgs.add(pkg)
    eval_build(pkg)
    for l, srcs in SRC_OVERRIDES.items():
      if l.startswith('//' + pkg + ':') and l in targets:
        targets[l]['srcs'] = srcs
    for l, srcs in EXTRA_SRCS.items():
      if l.startswith('//' + pkg + ':') and l in targets:
        targets[l]['srcs'] = SelList([targets[l].get('srcs', []), srcs])
  return targets.get(lab)


# ---- target graph ----------------------------------------------------------
# Paths use ninja variables: $src (Mozc src), $gen (generated files),
# $obj (objects).

def outputs_of(t):
  """Files produced by target t, relative to $gen."""
  k, pkg = t['kind'], t['pkg']
  if k in ('genrule', 'run_binary'):
    return [pkg + '/' + o for o in resolve(t['outs'])]
  if k == 'run_build_tool':
    return [pkg + '/' + o for o in resolve(t['outs_map']).values()]
  if k == 'cc_proto_library':
    res = []
    for d in resolve(t['deps']):
      p = get(label_of(d, pkg))
      for s in resolve(p['srcs']):
        b = p['pkg'] + '/' + s[:-len('.proto')]
        res += [b + '.pb.cc', b + '.pb.h']
    return res
  return []


def files_of(label, pkg):
  """Resolve a label to (kind, value) entries.

  kind: 'src' / 'gen' / 'xfile' (a file), 'tool' (an executable target),
  'lib' (a library), 'rule' (a generating target to emit), 'ext' (unknown
  external label).
  """
  lab = label_of(label, pkg)
  if lab.startswith('@'):
    repo, _, rest = lab[1:].partition('//')
    xp = os.path.join(EXT, repo, rest.split(':')[-1]).replace(os.sep, '/')
    if os.path.isfile(xp):
      return [('xfile', xp)]
    return [('ext', lab)]
  t = get(lab)
  if t is None:
    p, _, n = lab[2:].partition(':')
    return [('src', (p + '/' + n) if p else n)]
  k = t['kind']
  if k == 'filegroup':
    return [e for s in resolve(t.get('srcs', [])) for e in files_of(s, t['pkg'])]
  if k == 'alias':
    return files_of(resolve(t['actual']), t['pkg'])
  if k in ('cc_binary', 'py_binary'):
    return [('tool', lab)]
  if k in ('cc_library', 'proto_library', 'py_library'):
    return [('lib', lab)]
  return [('gen', o) for o in outputs_of(t)] + [('rule', lab)]


FILE_KINDS = ('src', 'gen', 'xfile')


def path_of(entry):
  kind, p = entry
  return {'src': '$src/', 'gen': '$gen/', 'xfile': ''}[kind] + p


def exe_path(lab):
  pkg, _, n = lab[2:].partition(':')
  return '$gen/' + pkg + '/' + n + '.exe'


def tool_cmd(lab):
  t = get(lab)
  if t['kind'] == 'py_binary':
    main = t.get('main') or resolve(t['srcs'])[0]
    return 'python $src/' + t['pkg'] + '/' + main
  return exe_path(lab)


def tool_deps(lab):
  t = get(lab)
  if t['kind'] == 'py_binary':
    return ['$src/' + t['pkg'] + '/' + s for s in resolve(t['srcs'])]
  need_binary(lab)
  return [exe_path(lab)]


def collect_files(labels, pkg):
  """Paths of the files behind labels; emits generating targets."""
  paths = []
  for s in labels:
    for e in files_of(s, pkg):
      if e[0] in FILE_KINDS:
        paths.append(path_of(e))
      elif e[0] == 'rule':
        emit_rule_target(e[1])
      elif e[0] == 'ext':
        # Silently dropping it would build data without that input (e.g. an
        # empty usage dictionary), so stop and say what to download.
        repo, _, rest = e[1][1:].partition('//')
        sys.exit('mini_bazel: external file %s is not found at %s/%s/%s; '
                 'add the http_archive "%s" from MODULE.bazel to $externals '
                 'in build.ps1' % (e[1], EXT, repo, rest.split(':')[-1], repo))
  return paths


# ---- ninja emission --------------------------------------------------------

ninja = []
emitted = set()
binaries = set()
lib_info = {}  # label -> (objs, generated headers, defines)


def nesc(p):
  """Escape a path that may contain $src/$gen references."""
  return p.replace(' ', '$ ').replace(':', '$:')


def write_if_changed(path, text):
  """Keep mtimes stable so regenerating build.ninja doesn't rebuild."""
  try:
    with open(path, encoding='utf-8', newline='') as f:
      if f.read() == text:
        return
  except OSError:
    pass
  with open(path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(text)


def emit_rule_target(lab):
  """Emit build statements for a generating target."""
  if lab in emitted:
    return
  emitted.add(lab)
  t = get(lab)
  k, pkg = t['kind'], t['pkg']

  if k == 'cc_proto_library':
    for d in resolve(t['deps']):
      p = get(label_of(d, pkg))
      for s in resolve(p['srcs']):
        b = '$gen/' + p['pkg'] + '/' + s[:-len('.proto')]
        ninja.append('build %s %s: protoc $src/%s/%s' % (
            nesc(b + '.pb.cc'), nesc(b + '.pb.h'), p['pkg'], s))
    return

  if k == 'run_build_tool':
    # Run directly (no shell); arguments are argparse-style.
    tool = label_of(t['tool'], pkg)
    args = list(resolve(t['args']))
    ins = []
    for opt, srcs in resolve(t['srcs_map']).items():
      paths = collect_files(resolve(srcs), pkg)
      args += [opt] + paths
      ins += paths
    outs = []
    for opt, o in resolve(t['outs_map']).items():
      outs.append('$gen/' + pkg + '/' + o)
      args += [opt, outs[-1]]
    if t['positional_srcs']:
      paths = collect_files(resolve(t['positional_srcs']), pkg)
      args += ['--'] + paths
      ins += paths
    ninja.append('build %s: cmd %s | %s\n  cmd = %s\n  desc = %s' % (
        ' '.join(map(nesc, outs)), ' '.join(map(nesc, ins)),
        ' '.join(map(nesc, tool_deps(tool))),
        tool_cmd(tool) + ' ' + ' '.join(args), lab))
    return

  if k in ('genrule', 'run_binary'):
    outs = ['$gen/' + pkg + '/' + o for o in resolve(t['outs'])]
    ins = []
    locmap = {}
    for s in resolve(t.get('srcs', [])):
      paths = collect_files([s], pkg)
      ins += paths
      locmap[label_of(s, pkg)] = paths
    tdeps = []
    tools = resolve(t.get('tools', [])) + resolve(t.get('exec_tools', []))
    if k == 'run_binary':
      tools.append(t['tool'])
    for tl in tools:
      full = label_of(tl, pkg)
      tt = get(full)
      if tt and tt['kind'] in ('cc_binary', 'py_binary'):
        locmap[full] = [tool_cmd(full)]
        tdeps += tool_deps(full)
      else:
        locmap[full] = collect_files([tl], pkg)
        tdeps += locmap[full]
    for o in resolve(t['outs']):
      locmap[label_of(o, pkg)] = ['$gen/' + pkg + '/' + o]
    if k == 'run_binary':
      cmd = tool_cmd(label_of(t['tool'], pkg)) + ' ' + ' '.join(
          resolve(t['args']))
    else:
      cmd = resolve(t['cmd'])

    def loc(m):
      arg = label_of(m.group(2).strip(), pkg)
      if arg not in locmap:
        raise KeyError('%s: unknown location %s' % (lab, arg))
      return ' '.join(locmap[arg])

    cmd = re.sub(r'\$\((locations?|execpaths?|rootpaths?) ([^)]*)\)', loc, cmd)
    cmd = (cmd.replace('$(SRCS)', ' '.join(ins))
           .replace('$(OUTS)', ' '.join(outs))
           .replace('$@', outs[0]).replace('$<', ins[0] if ins else '')
           .replace('$(@D)', os.path.dirname(outs[0]) if len(outs) == 1
                    else '$gen/' + pkg)
           .replace('$(RULEDIR)', '$gen/' + pkg)
           .replace('$(GENDIR)', '$gen').replace('$(BINDIR)', '$gen')
           .replace('$(PYTHON3)', 'python'))
    # Run each genrule as a shell script with concrete relative paths.  This
    # sidesteps quoting through ninja and CreateProcess.  Bazel's '$$' is a
    # literal '$' for the shell.
    def concrete(s):
      return s.replace('$gen/', 'gen/').replace('$src/', RELSRC + '/')
    script = 'set -e\nmkdir -p %s\n%s\n' % (
        ' '.join(sorted({concrete(os.path.dirname(o)) for o in outs})),
        concrete(cmd).replace('$$', '$'))
    sdir = os.path.join(OUT, 'cmds')
    os.makedirs(sdir, exist_ok=True)
    spath = 'cmds/' + re.sub(r'[^A-Za-z0-9_.-]', '_', lab[2:]) + '.sh'
    write_if_changed(os.path.join(OUT, spath), script)
    ninja.append('build %s: shcmd %s | %s %s\n  script = %s\n  desc = %s' % (
        ' '.join(map(nesc, outs)), ' '.join(map(nesc, ins)),
        ' '.join(map(nesc, tdeps)), spath, spath, lab))
    return

  raise ValueError('cannot emit %s (%s)' % (lab, k))


def cc_closure(lab, seen=None, order=None):
  """Transitive deps of lab in post order (lab last)."""
  if seen is None:
    seen, order = set(), []
  if lab in seen:
    return order
  seen.add(lab)
  t = get(lab)
  if t is not None:
    if t['kind'] == 'alias':
      return cc_closure(label_of(resolve(t['actual']), t['pkg']), seen, order)
    for d in (resolve(t.get('deps', [])) +
              resolve(t.get('implementation_deps', []))):
      cc_closure(label_of(d, t['pkg']), seen, order)
  order.append(lab)
  return order


def emit_cc(lab):
  """Emit compile statements for a C++ target."""
  if lab in lib_info:
    return lib_info[lab]
  t = get(lab)
  pkg = t['pkg']
  objs, gens, srcs = [], [], []
  if t['kind'] == 'cc_proto_library':
    emit_rule_target(lab)
    for o in outputs_of(t):
      (srcs if o.endswith('.cc') else gens).append('$gen/' + o)
    copts, defines = [], []
  else:
    own_srcs = resolve(t.get('srcs', []))
    for s in (own_srcs + resolve(t.get('hdrs', [])) +
              resolve(t.get('textual_hdrs', []))):
      for e in files_of(s, pkg):
        if e[0] == 'rule':
          emit_rule_target(e[1])
        elif e[0] in ('src', 'gen'):
          p = path_of(e)
          if p.endswith(('.cc', '.c', '.cpp')) and s in own_srcs:
            srcs.append(p)
          elif e[0] == 'gen':
            gens.append(p)
    copts = [c for c in resolve(t.get('copts', [])) if not c.startswith('$(')]
    copts += ['-D' + d for d in resolve(t.get('local_defines', []))]
    defines = ['-D' + d for d in resolve(t.get('defines', []))]
  lib_info[lab] = (objs, gens, defines)

  # Generated headers and defines of the transitive deps.
  tdefs = list(defines)
  tgens = list(gens)
  for d in cc_closure(lab)[:-1]:
    dt = get(d)
    if dt is None or dt['kind'] not in ('cc_library', 'cc_proto_library'):
      continue
    _, g2, df2 = emit_cc(d)
    tgens += g2
    tdefs += df2
  for s in srcs:
    obj = '$obj/' + lab[2:].replace(':', '/') + '/' + os.path.basename(s) + '.o'
    ninja.append('build %s: %s %s || %s\n  flags = %s' % (
        nesc(obj), 'cc' if s.endswith('.c') else 'cxx', nesc(s),
        ' '.join(map(nesc, sorted(set(tgens)))),
        ' '.join(sorted(set(tdefs)) + copts)))
    objs.append(obj)
  return lib_info[lab]


def need_binary(lab):
  if lab in binaries:
    return
  binaries.add(lab)
  t = get(lab)
  objs = []
  libs = []
  for l in resolve(t.get('linkopts', [])):
    if l.startswith('-l'):
      libs.append(l)
  for d in cc_closure(lab):
    dt = get(d)
    if dt is None or dt['kind'] not in ('cc_library', 'cc_binary',
                                        'cc_proto_library'):
      continue
    objs += emit_cc(d)[0]
    libs += [l for l in resolve(dt.get('linkopts', [])) if l.startswith('-l')]
  ninja.append('build %s: link %s\n  libs = %s' % (
      nesc(exe_path(lab)), ' '.join(map(nesc, objs)),
      ' '.join(dict.fromkeys(libs))))


HEADER = '''# Generated by mini_bazel.py.  Do not edit.
src = {relsrc}
gen = gen
obj = obj
prefix = {prefix}
cxxflags = -std=c++20 -O2 -DNDEBUG -DMOZC_BUILD -D_WIN32_WINNT=0x0A00 $
    -DUNICODE -D_UNICODE -DNOMINMAX -DWIN32_LEAN_AND_MEAN $
    -D__nullptr=nullptr -funsigned-char -w $
    -I$src -I$gen -I$prefix/include -I{wil} -I{compat}
cflags = -O2 -I$src -I$gen -I$prefix/include
deplibs = {deplibs}
syslibs = -lshlwapi -lole32 -luuid -lshell32 -ladvapi32 -lversion -luser32 $
    -lbcrypt -ldbghelp -lsynchronization -limm32 -lpathcch -lntdll -lpsapi $
    -lwtsapi32 -luserenv -lcrypt32 -lws2_32

rule cxx
  command = g++ $cxxflags $flags -MD -MF $out.d -c $in -o $out
  depfile = $out.d
  deps = gcc
  description = CXX $in
rule cc
  command = gcc $cflags $flags -MD -MF $out.d -c $in -o $out
  depfile = $out.d
  deps = gcc
  description = CC $in
rule link
  command = g++ -static -O2 -o $out @$out.rsp -Wl,--start-group $deplibs $
      -Wl,--end-group $libs $syslibs
  rspfile = $out.rsp
  rspfile_content = $in
  description = LINK $out
rule protoc
  command = $prefix/bin/protoc.exe -I$src -I$prefix/include --cpp_out=$gen $in
  description = PROTOC $in
rule cmd
  command = $cmd
  description = $desc
rule shcmd
  command = sh $script
  description = $desc

'''


def main():
  for r in ARGS.targets:
    lab = label_of(r, '')
    t = get(lab)
    if t is None:
      sys.exit('no such target ' + lab)
    if t['kind'] == 'cc_binary':
      need_binary(lab)
    elif t['kind'] in ('cc_library', 'cc_proto_library'):
      emit_cc(lab)
    else:
      emit_rule_target(lab)
  # All abseil / protobuf archives; the linker picks what it needs.  The lite
  # runtime duplicates libprotobuf, and libprotoc is the compiler.
  deplibs = sorted(
      a.replace(os.sep, '/') for a in _glob.glob(PREFIX + '/lib/lib*.a')
      if not re.search(r'libproto(c|buf-lite)\.a$', a))
  head = HEADER.format(relsrc=RELSRC, prefix=PREFIX, wil=_abs(ARGS.wil),
                       compat=_abs(ARGS.compat), deplibs=' '.join(deplibs))
  os.makedirs(OUT, exist_ok=True)
  write_if_changed(os.path.join(OUT, 'build.ninja'),
                   head + '\n'.join(ninja) + '\n')
  print('mini_bazel: %d build statements' % len(ninja))


main()
