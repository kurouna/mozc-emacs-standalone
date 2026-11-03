# 変換精度の評価

`mozc_eval.py` は `mozc_emacs_helper.exe` を mozc.el と同じ S 式で動かし、読みを
スペースで変換した結果を正解と比べます。helper を差し替えて測れば、エンジンへの
パッチの効果を A/B で比べられます。Python 3（標準ライブラリだけ）で動きます。

```
python eval/mozc_eval.py run --helper dist/mozc_emacs_helper.exe --data <データ> --out eval/results/base.json
python eval/mozc_eval.py compare eval/results/base.json eval/results/new.json
```

- helper は毎回空の一時プロファイル（`--profile_dir`）で起動し、変換結果は確定せずに
  取り消すので、普段の学習データには触れず、項目の順番にも左右されません
- `--show-errors` で不正解の項目を、`--limit N` で先頭 N 件だけを測れます

## データ

| 形式 | 例 | 判定 |
|:---|:---|:---|
| Mozc の品質回帰テスト TSV | `src/data/test/quality_regression_test/oss.tsv`, `regression.tsv` | `Conversion Expected [N]` などの規則（予測・サジェストの項目は対象外） |
| 読みと正解の TSV | `reading<TAB>正解[<TAB>別解...]` | 1 位の一致、文字誤り率、候補内に正解があるか |
| AJIMEE-Bench の JSON | `evaluation_items.json` | 同上。文脈あり／なしを分けて集計 |

Mozc の TSV は `build.ps1` が取得した Mozc（`<WorkDir>\mozc\src\data\test\...`）にあります。
取得した評価データは `eval/data/` に置きます（`.gitignore` 済み。ライセンス上、
このリポジトリでは配布しません）。

## 学習の効果

```
python eval/mozc_eval.py learn --helper dist/mozc_emacs_helper.exe --data eval/data/evaluation_items.json --out eval/results/learn.json
```

文の項目を交互に「学習させる組」と「学習させない組」に分け、学習させる組の正解を
候補から選んで確定してから（区切り直しが要る項目は学習させない）、もう一度変換します。

- **同じ読みで再変換**：確定したときと同じ入力
- **前／後ろに別の読みを付けて変換**：学習させない組の読みをつなげた入力。文節の区切りが
  学習時と変わっても効くかを見る（正解が出力の末尾／先頭にそのまま現れれば正解）
- **学習していない項目**：学習させない組。悪化していれば学習の副作用

確定のたびにセッションを作り直すので、直前に確定した文節は次の変換の文脈になりません。
helper に渡す引数は `--helper-arg=...` で足せます（`run` も同じ）。

## 直前の文字列（文脈）

```
python eval/mozc_eval.py run --helper dist/mozc_emacs_helper.exe --send-context --data eval/data/evaluation_items.json
python eval/mozc_eval.py move --helper dist/mozc_emacs_helper.exe --data eval/data/evaluation_items.json
```

- `--send-context`：AJIMEE-Bench の `context_text` を、`mozc-context.el` と同じく `SetContext` で
  helper に渡してから変換します（文脈の無い項目は空文字列）。受け取れない helper には送りません
- `move`：各項目の前に、ひとつ前の項目を 1 位のまま確定し、カーソル移動のキー（`--move-key`、
  既定は `left`）を送ってから変換します。カーソルを動かしたあとに、前の場所の文脈が残るかを見る。
  `--move-key none` ならキーを送りません（mozc.el が helper に送らないマウスのクリックで動いた場合）

このリポジトリにある、文脈を見るための小さなデータ（AJIMEE-Bench と同じ形式）:

| ファイル | 内容 |
|:---|:---|
| `eval/context_cases.json` | 30 問。文脈が効くはずのもの（地名＋海・都など、助詞）と、文脈で悪くならないかを見るもの（句読点・括弧のあと、コードのコメント、英数字の混在、URL、長い行、記号だけ、空） |
| `eval/click_cases.json` | `move --move-key none` 用。前の項目で「日本」「東京」などを確定し、別の文脈の場所で「かい」「と」などを変換する 6 組（y で始まる項目を見る） |

`mozc-context.el` を入れた helper（patches/0002 と SetContext）での結果（変更前 → 文脈あり）:

| データ | 変更前 | 文脈あり |
|:---|:---|:---|
| AJIMEE-Bench 200 問（`run --send-context`） | 102（文脈つき 45/100） | 104（文脈つき 47/100）、悪化 0 |
| `context_cases.json` 30 問（`run --send-context`） | 24 | 28、悪化 0 |
| `click_cases.json` の y 6 問（`move --move-key none --send-context`） | 0（前の場所の文脈で「海」「都」など） | 6 |
| Mozc の品質回帰テスト 613 問 | 437 | 437、変化なし |
| 最初のキーの処理時間（中央値 / 最大） | 2.2ms / 8.5ms | 8.2ms / 26.9ms |

## 集計の見方

- **正解**：規則の項目は規則を満たした数、文の項目は 1 位（スペース 1 回の結果）が正解と一致した数
- **文字誤り率**：1 位と正解の編集距離の合計 ÷ 正解の文字数の合計
- **候補内に正解**：各文節の候補を選び直せば正解にたどり着ける項目の数
- **変換時間**：スペースを送ってから応答が返るまで。mozc.el は 1 秒で打ち切るので、
  エンジンに処理を足したときはここを見る
