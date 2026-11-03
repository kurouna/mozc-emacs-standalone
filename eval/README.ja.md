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

## 集計の見方

- **正解**：規則の項目は規則を満たした数、文の項目は 1 位（スペース 1 回の結果）が正解と一致した数
- **文字誤り率**：1 位と正解の編集距離の合計 ÷ 正解の文字数の合計
- **候補内に正解**：各文節の候補を選び直せば正解にたどり着ける項目の数
- **変換時間**：スペースを送ってから応答が返るまで。mozc.el は 1 秒で打ち切るので、
  エンジンに処理を足したときはここを見る
