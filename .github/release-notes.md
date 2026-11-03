A prebuilt `mozc_emacs_helper.exe` with the Mozc engine and dictionary inside, for using Mozc as a `C-\` input method in GNU Emacs on Windows (x64). No IME to install and no `mozc_server`.

Windows (x64) の GNU Emacs で Mozc を `C-\` の入力メソッドとして使うための、変換エンジンと辞書を内蔵した `mozc_emacs_helper.exe` のビルド済み版です。IME のインストールも `mozc_server` も要りません。

### Contents / 中身

`{ZIP_NAME}`

| File | Contents |
|:---|:---|
| `mozc_emacs_helper.exe` | The helper with the Mozc engine and dictionary inside / Mozc の変換エンジンと辞書を内蔵した helper |
| `mozc.el` | Mozc's official `mozc.el` of the same version / 同じ版の Mozc 公式 `mozc.el` |
| `mozc-user-dict.el` | Edits the user dictionary from Emacs / Emacs からユーザー辞書を編集する |
| `LICENSES\` | License texts of what the exe contains / exe に含まれるもののライセンス文 |
| `README.md` / `README.ja.md` | Setup and usage / 設定と使い方 |
| `docs\` | Screenshots shown in the READMEs / README の画面写真 |

Extract it, put the files somewhere, and set up Emacs as in the README ("Use from Emacs" / 「Emacs で使う」).

展開してファイルを好きな場所に置き、README の「Emacs で使う」のとおりに設定してください。

### Built from / ビルド元

Built by GitHub Actions. / GitHub Actions でビルドしています。

| | |
|:---|:---|
| This repository | `{VERSION}` |
| Mozc | [`{MOZC_SHORT}`](https://github.com/google/mozc/commit/{MOZC_COMMIT}) (open-source dictionary) |
| Compiler | w64devkit {W64DEVKIT_VERSION} |

The versions of abseil-cpp, protobuf and WIL are pinned in `build.ps1`. / abseil-cpp・protobuf・WIL の版は `build.ps1` で固定しています。

### Licenses / ライセンス

The exe contains Mozc (BSD 3-Clause), its dictionary data (IPAdic and Okinawa dictionary licenses), the usage dictionary (BSD 2-Clause), abseil-cpp (Apache 2.0), protobuf (BSD 3-Clause), WIL (MIT) and the MinGW-w64 runtime. Their license texts are in `LICENSES\`; keep them with the exe when you pass it on. This project is not affiliated with Google.

exe には上記のものが含まれます。ライセンス文は `LICENSES\` にあるので、exe を人に渡すときは一緒に渡してください。このプロジェクトは Google とは関係のない、個人によるものです。

SHA-256 (`{ZIP_NAME}`): `{ZIP_SHA256}`
