# Copyright 2026, Shinsaku Nakagawa
# Use of this source code is governed by the BSD 3-Clause license in LICENSE.
#
# Mozc の変換エンジンと辞書を内蔵した mozc_emacs_helper.exe をビルドする。
#
#   .\build.ps1
#   .\build.ps1 -DevkitBin C:\w64devkit\bin -WorkDir D:\mozc-build -OutDir $env:APPDATA\.emacs.d\mozc
#
# 必要なもの: w64devkit (gcc/g++/cmake/ninja/sh)、git、Python 3 (PATH 上の python)。
# Bazel は使わない。Mozc の BUILD.bazel を mini_bazel.py で読んで build.ninja を
# 生成し、辞書データの生成からリンクまでを ninja で行う。
# 初回は abseil / protobuf のビルドを含めて 10〜20 分ほどかかる。
#
# OutDir に次のものを書き出す:
#   mozc_emacs_helper.exe  helper（エンジンと辞書を内蔵）
#   mozc.el                同じ版の Mozc 公式 mozc.el（1 行目にクッキーを追加）
#   LICENSES\              exe に含まれるもののライセンス文
param(
  [string]$DevkitBin = 'D:\w64devkit\bin',
  [string]$WorkDir   = (Join-Path $env:TEMP 'mozc-build'),
  [string]$OutDir    = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'

# ---- 使うソースの版 --------------------------------------------------------
# abseil / protobuf は Mozc の src/MODULE.bazel が指定している版に合わせる。
# WIL は MinGW (gcc) に対応した版が必要（v1.0.230629.1 では通らない）。
$mozc     = @('https://github.com/google/mozc', 'e5f1494923a0a624d01f19c50d57bbdfa03ea5ba')
$abseil   = @('https://github.com/abseil/abseil-cpp', '20260107.1')
$protobuf = @('https://github.com/protocolbuffers/protobuf', 'v34.1')
$wil      = @('https://github.com/microsoft/wil', 'a1c0cbe1d7065aef6333399d3e25608eacdffc0f')
# 辞書データの元になる外部ファイル。MODULE.bazel の http_archive と同じもの。
#   リポジトリ名 (@名前), URL, SHA-256, 展開後に外すディレクトリ (strip_prefix)
# 展開先は <作業ディレクトリ>\external\<リポジトリ名>\ で、mini_bazel.py が
# "@名前//:ファイル" をここから探す。
$externals = @(
  @('zip_code_ken_all',
    'https://github.com/hiroyuki-komatsu/japanpost_zipcode/raw/621d059fbcbfae17bfca15b439692bae934268c3/ken_all.zip',
    '3adc97d8e19e1168a6cdcb2fce759d0e9e613a9a3b630cc180aecfd56ae81eaf', ''),
  @('zip_code_jigyosyo',
    'https://github.com/hiroyuki-komatsu/japanpost_zipcode/raw/621d059fbcbfae17bfca15b439692bae934268c3/jigyosyo.zip',
    '14be1030f607c5f819f2f45a485e89511907bdd1d62e7fb1931b6e48a3431c3a', ''),
  @('ja_usage_dict',
    'https://github.com/hiroyuki-komatsu/japanese-usage-dictionary/archive/refs/tags/2025-01-25.zip',
    '140f24f71f7d78d5eb5b93a9c079f44f23728dca5ab16bf857fe8a3fa1bf20ed', 'japanese-usage-dictionary-2025-01-25')
)

if (-not (Test-Path (Join-Path $DevkitBin 'gcc.exe'))) {
  throw "gcc.exe not found in $DevkitBin — w64devkit の bin を -DevkitBin で指定してください"
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  throw 'python が見つかりません — Python 3 を PATH に入れてください'
}
$env:Path = "$DevkitBin;$env:Path"
New-Item -ItemType Directory -Force $WorkDir | Out-Null

# 外部コマンドを実行し、失敗したら止める。
# param() を書くと -o などが PowerShell の共通パラメーターと解釈されるので $args で受ける。
function Invoke-Native {
  $exe, $rest = $args
  & $exe @rest
  if ($LASTEXITCODE -ne 0) { throw "$exe failed (exit $LASTEXITCODE)" }
}

# タグ/コミットを 1 つだけ取ってくる。取ってきた版は .mozc-build-rev に記録し、
# 上の版を書き換えたときだけ取り直す（作業ディレクトリを残したまま更新できる）。
function Get-Source($spec, $dir) {
  $repo, $rev = $spec
  $stamp = Join-Path $dir '.git\mozc-build-rev'
  if ((Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $rev)) { return }
  Write-Host "== fetch $repo @ $rev"
  if (-not (Test-Path (Join-Path $dir '.git'))) {
    Invoke-Native git init -q $dir
    Invoke-Native git -C $dir remote add origin $repo
  }
  Invoke-Native git -C $dir fetch -q --depth 1 origin $rev
  Invoke-Native git -C $dir checkout -q -f FETCH_HEAD
  Set-Content -NoNewline -LiteralPath $stamp -Value $rev
}

# UTF-8 (BOM なし) / LF で書く。PowerShell 5.1 の Set-Content は BOM を付けるので使わない。
function Write-Utf8Lf($path, $text) {
  [System.IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"),
                                 (New-Object System.Text.UTF8Encoding $false))
}

$mozcDir = Join-Path $WorkDir 'mozc'
$abslDir = Join-Path $WorkDir 'abseil-cpp'
$pbDir   = Join-Path $WorkDir 'protobuf'
$wilDir  = Join-Path $WorkDir 'wil'
$prefix  = Join-Path $WorkDir 'prefix'
$extDir  = Join-Path $WorkDir 'external'
$buildDir = Join-Path $WorkDir 'out'   # ninja のビルドディレクトリ（-OutDir とは別）

Get-Source $mozc     $mozcDir
Get-Source $abseil   $abslDir
Get-Source $protobuf $pbDir
Get-Source $wil      $wilDir

# ---- Mozc が要求する版と、ここで固定した版が合っているか ----------------------
# Mozc を更新したら src/MODULE.bazel の abseil / protobuf / 外部ファイルも
# 変わっていることがある。食い違ったら、直すべき値を表示して止める。
$module = Get-Content -Raw (Join-Path $mozcDir 'src\MODULE.bazel')
$mismatch = @()
foreach ($dep in @(@('abseil-cpp', $abseil[1]), @('protobuf', ($protobuf[1] -replace '^v', '')))) {
  $m = [regex]::Match($module, 'name = "' + [regex]::Escape($dep[0]) + '",\s*version = "([^"]+)"')
  if ($m.Success -and $m.Groups[1].Value -ne $dep[1]) {
    $mismatch += "$($dep[0]): MODULE.bazel は $($m.Groups[1].Value)、build.ps1 は $($dep[1])"
  }
}
foreach ($x in $externals) {
  $m = [regex]::Match($module, '(?s)name = "' + [regex]::Escape($x[0]) + '",.*?sha256 = "([0-9a-f]+)"')
  if (-not $m.Success) {
    $mismatch += "$($x[0]): MODULE.bazel に見つかりません（不要になったなら `$externals から外す）"
  } elseif ($m.Groups[1].Value -ne $x[2]) {
    $mismatch += "$($x[0]): MODULE.bazel の sha256 は $($m.Groups[1].Value)。URL / strip_prefix も合わせて直す"
  }
}
# MODULE.bazel で新しく増えた外部ファイルは、mini_bazel.py がビルド時に
# 「外部ファイルが見つからない」として止めるので、ここに足す。
if ($mismatch.Count -gt 0) {
  throw ("Mozc が要求する版と build.ps1 の固定値が違います。build.ps1 の先頭を直してください:`n  " +
         ($mismatch -join "`n  "))
}

# ---- Mozc に MinGW 用のパッチと追加パッケージを当てる ------------------------
# 毎回まっさらな状態から当て直す（パッチを直したときに二重に当たらないように）
Write-Host '== patch mozc'
Invoke-Native git -C $mozcDir checkout -q -- .
Invoke-Native git -C $mozcDir clean -q -fd -- src/emacs_standalone
foreach ($p in Get-ChildItem (Join-Path $PSScriptRoot 'patches\*.patch') | Sort-Object Name) {
  Invoke-Native git -C $mozcDir apply --whitespace=nowarn $p.FullName
}
Copy-Item -Recurse -Force (Join-Path $PSScriptRoot 'emacs_standalone') (Join-Path $mozcDir 'src')

# ---- 辞書データの元になる外部ファイル ----------------------------------------
foreach ($x in $externals) {
  $name, $url, $sha, $strip = $x
  $dir = Join-Path $extDir $name
  $stamp = Join-Path $dir 'sha256.txt'
  if ((Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $sha)) { continue }
  Write-Host "== download $url"
  $zipPath = Join-Path $extDir "$name.zip"
  New-Item -ItemType Directory -Force $extDir | Out-Null
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zipPath
  $actual = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()
  if ($actual -ne $sha) { throw "$name の SHA-256 が一致しません ($actual)" }
  Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
  $tmp = "$dir.tmp"
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  Expand-Archive -Force $zipPath $tmp
  Move-Item (Join-Path $tmp $strip) $dir
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  Set-Content -NoNewline -LiteralPath $stamp -Value $sha
}

# ---- abseil / protobuf ------------------------------------------------------
# Mozc は C++20 で、abseil の ABI はこれに合わせる必要がある。
$cmakeCommon = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_STANDARD=20',
                 "-DCMAKE_INSTALL_PREFIX=$prefix", "-DCMAKE_PREFIX_PATH=$prefix",
                 '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_C_COMPILER=gcc', '-DCMAKE_CXX_COMPILER=g++')
# どの版でビルドしたかを prefix に記録し、版を変えたら作り直す
$depsStamp = Join-Path $prefix 'mozc-build-deps.txt'
$depsRev = "abseil=$($abseil[1]) protobuf=$($protobuf[1])"
if ((Test-Path $depsStamp) -and ((Get-Content $depsStamp -Raw).Trim() -ne $depsRev)) {
  Write-Host '== abseil / protobuf の版が変わったので作り直します'
  foreach ($d in @($prefix, (Join-Path $WorkDir 'b-absl'), (Join-Path $WorkDir 'b-pb'))) {
    Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
  }
}
if (-not (Test-Path (Join-Path $prefix 'lib\cmake\absl'))) {
  Write-Host '== build abseil'
  Invoke-Native cmake -S $abslDir -B (Join-Path $WorkDir 'b-absl') @cmakeCommon `
    -DABSL_PROPAGATE_CXX_STD=ON -DABSL_BUILD_TESTING=OFF
  Invoke-Native cmake --build (Join-Path $WorkDir 'b-absl')
  Invoke-Native cmake --install (Join-Path $WorkDir 'b-absl')
}
if (-not (Test-Path (Join-Path $prefix 'bin\protoc.exe'))) {
  Write-Host '== build protobuf'
  Invoke-Native cmake -S $pbDir -B (Join-Path $WorkDir 'b-pb') @cmakeCommon `
    -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_ABSL_PROVIDER=package `
    -Dprotobuf_BUILD_CONFORMANCE=OFF -Dprotobuf_BUILD_EXAMPLES=OFF
  Invoke-Native cmake --build (Join-Path $WorkDir 'b-pb')
  Invoke-Native cmake --install (Join-Path $WorkDir 'b-pb')
}
Set-Content -NoNewline -LiteralPath $depsStamp -Value $depsRev

# ---- Mozc 本体と辞書データ ---------------------------------------------------
Write-Host '== generate build.ninja'
$mozcSrc = Join-Path $mozcDir 'src'
Invoke-Native python (Join-Path $PSScriptRoot 'mini_bazel.py') `
  --src $mozcSrc --out $buildDir --prefix $prefix `
  --wil (Join-Path $wilDir 'include') --compat (Join-Path $PSScriptRoot 'compat') `
  --external $extDir '//emacs_standalone:mozc_emacs_helper'

Write-Host '== build mozc_emacs_helper'
# 辞書データ生成の Python スクリプトは src/ を起点に import する
$env:PYTHONPATH = $mozcSrc
Invoke-Native ninja -C $buildDir

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutFile = Join-Path $OutDir 'mozc_emacs_helper.exe'
$newFile = "$OutFile.new"
Invoke-Native strip -o $newFile (Join-Path $buildDir 'gen\emacs_standalone\mozc_emacs_helper.exe')
# Emacs が helper を使っている間は exe を上書きできない。実行中の exe でも
# 名前は変えられるので、古い方を .old に退避してから置き換える
# （.old は次回のビルドで消す）。
Remove-Item -Force "$OutFile.old" -ErrorAction SilentlyContinue
try {
  Move-Item -Force $newFile $OutFile -ErrorAction Stop
} catch {
  Move-Item -Force $OutFile "$OutFile.old"
  Move-Item -Force $newFile $OutFile
  Write-Host '    使用中だった古い exe は .old に退避しました。Emacs を再起動すると新しい exe が使われます'
}

# ---- exe と同じ版の mozc.el とライセンス文 -----------------------------------
# mozc.el は 1 行目に lexical-binding: nil のクッキーだけ足す（Emacs 31 の
# "Missing lexical-binding cookie" 警告対策。動作は変わらない）。
$el = Get-Content -Raw -Encoding UTF8 (Join-Path $mozcSrc 'unix\emacs\mozc.el')
$el = [regex]::Replace($el, '\A([^\r\n]*)', '$1  -*- lexical-binding: nil -*-')
Write-Utf8Lf (Join-Path $OutDir 'mozc.el') $el
# exe を配るときは、この LICENSES\ も一緒に配ること
$licDir = Join-Path $OutDir 'LICENSES'
New-Item -ItemType Directory -Force $licDir | Out-Null
Copy-Item -Force (Join-Path $mozcDir 'LICENSE') (Join-Path $licDir 'mozc.LICENSE')
Copy-Item -Force (Join-Path $abslDir 'LICENSE') (Join-Path $licDir 'abseil-cpp.LICENSE')
Copy-Item -Force (Join-Path $pbDir 'LICENSE') (Join-Path $licDir 'protobuf.LICENSE')
Copy-Item -Force (Join-Path $wilDir 'LICENSE') (Join-Path $licDir 'wil.LICENSE')
Copy-Item -Force (Join-Path $mozcSrc 'data\dictionary_oss\README.txt') (Join-Path $licDir 'mozc-dictionary_oss.README.txt')
Copy-Item -Force (Join-Path $extDir 'ja_usage_dict\LICENSE') (Join-Path $licDir 'japanese-usage-dictionary.LICENSE')
Copy-Item -Force (Join-Path $PSScriptRoot 'LICENSE') (Join-Path $licDir 'mozc-emacs-standalone.LICENSE')

Write-Host "`n=== OK: $OutDir"
Write-Host '    mozc_emacs_helper.exe / mozc.el / LICENSES\'
