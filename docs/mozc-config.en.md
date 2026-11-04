[日本語](mozc-config.md) | **English**

# Settings in mozc-config.el

The Mozc settings that `mozc-config.el` can change. Each can be changed in the list of `M-x mozc-config`,
and set from init.el with `mozc-config-set`.

```elisp
(require 'mozc-config)
(mozc-config-set 'space-character-form "半角")     ; always input a halfwidth space
(mozc-config-set 'punctuation-method "，．")       ; punctuation ，．
(mozc-config-set 'use-emoji-conversion nil)        ; no emoji conversion
(mozc-config-set 'suggestions-size 5)              ; up to 5 suggestions
```

- If you use `--profile_dir`, put these after setting `mozc-helper-program-args` (the settings file
  is found from it)
- It writes only when the value differs, and then restarts the helper so that it reloads the
  settings (at Emacs startup the helper is not running yet, so the first time you turn Mozc on it
  uses the new settings)
- `(mozc-config-get 'space-character-form)` returns the current value

## Values

The values are the Japanese texts shown in the list (and in Mozc's settings dialog). The tables
below give their meaning.

| Kind | Values | Example |
|:---|:---|:---|
| On/off | `t` / `nil`, or `"有効"` (on) / `"無効"` (off) | `(mozc-config-set 'use-calculator nil)` |
| Choice | The text in the "Values" column, or its number | `(mozc-config-set 'space-character-form "半角")` is the same as `(mozc-config-set 'space-character-form 2)` |
| Number | An integer in the range | `(mozc-config-set 'suggestions-size 5)` |
| Set of characters | A list of strings (the empty list for none) | `(mozc-config-set 'auto-conversion-key '("。" "？"))` |

"Default" is the value when nothing is set. Resetting an item to its default removes it from the
settings file.

## Basics

| Key | Item | Values | Default | Meaning |
|:---|:---|:---|:---|:---|
| `preedit-method` | Input mode | `"ローマ字入力"` romaji (0) / `"かな入力"` kana (1) / `"ローマ字入力 (切替可)"` romaji, switchable (2) / `"かな入力 (切替可)"` kana, switchable (3) | romaji | Type in romaji or with the kana keys. "Switchable" lets a key switch between them. Kana input uses mozc.el's kana layout (Japanese 106 keyboard by default, `mozc-keymap-kana`) |
| `punctuation-method` | Punctuation style | `"、。"` (0) / `"，．"` (1) / `"、．"` (2) / `"，。"` (3) | 、。 | What `,` and `.` input |
| `symbol-method` | Symbol style | `"「」・"` (0) / `"[]／"` (1) / `"「」／"` (2) / `"[]・"` (3) | 「」・ | What `[` `]` input (「」 or ［］) and what `/` inputs (・ or ／). With `"[]／"`, `[`, `]` and `/` give ［］／ |
| `space-character-form` | Space input style | `"入力モードに従う"` follow the input mode (0) / `"全角"` fullwidth (1) / `"半角"` halfwidth (2) | follow the input mode | The space typed when not converting. "Follow the input mode" gives a fullwidth space in hiragana mode. While converting, Space converts and cycles candidates in every case |
| `selection-shortcut` | Candidate selection shortcut | `"なし"` none (0) / `"1 -- 9"` (1) / `"A -- L"` (2) | 1 -- 9 | Pick candidates in the list with the digit keys (`1` to `9`) or the home row keys (`a` `s` `d` `f` `g` `h` `j` `k` `l`) |
| `numpad-character-form` | Input from numpad keys | `"入力モードに従う"` follow the input mode (0) / `"全角"` fullwidth (1) / `"半角"` halfwidth (2) / `"直接入力"` direct input (3) | halfwidth | Digits and symbols from the numpad. "Direct input" bypasses Mozc and inserts them as they are, even while converting |
| `yen-sign-character` | Input from ¥ or backslash key | `"円記号(¥)"` yen sign (0) / `"バックスラッシュ(\\)"` backslash (1) | yen sign | What the ¥ key of a Japanese keyboard inputs |

## Keymap

| Key | Item | Values | Default | Meaning |
|:---|:---|:---|:---|:---|
| `session-keymap` | Keymap style | `"ATOK"` (1) / `"MS-IME"` (2) / `"ことえり"` Kotoeri (3) | MS-IME | Which IME the keys used while converting follow. A custom keymap, which defines each key, needs a table editor and cannot be chosen (if set by other means, it shows as `カスタム`, custom) |

## Personalization

| Key | Item | Values | Default | Meaning |
|:---|:---|:---|:---|:---|
| `history-learning-level` | Adjust conversion based on previous input | `"有効"` yes (0) / `"有効（新規学習はしない）"` yes, but don't record new data (1) / `"無効"` no (2) | yes | Whether conversion results are learned and used to order candidates. "Don't record new data" uses what was learned but learns nothing new |

## Special conversions

All are `t` (on) / `nil` (off), and on by default.

| Key | Item | Meaning |
|:---|:---|:---|
| `use-single-kanji-conversion` | Single kanji conversion | Offer single kanji as candidates too |
| `use-symbol-conversion` | Symbol conversion | Offer symbols from readings such as きごう and やじるし |
| `use-emoticon-conversion` | Emoticon conversion | Offer emoticons from readings such as かお |
| `use-date-conversion` | Date/time conversion | Offer dates and times from きょう, いま and so on |
| `use-emoji-conversion` | Emoji conversion | Offer emoji from readings |
| `use-number-conversion` | Special number conversion | Offer kanji numerals, circled numbers, Roman numerals and so on for numbers |
| `use-calculator` | Calculator | Offer the result of expressions such as `12*3+4=` |
| `use-t13n-conversion` | Katakana to English conversion | Offer English words for katakana words |
| `use-zip-code-conversion` | Postal code conversion | Offer addresses for postal codes |
| `use-spelling-correction` | Spelling correction | Offer corrected candidates for readings that look mistyped |

## Input assistance

| Key | Item | Values | Default | Meaning |
|:---|:---|:---|:---|:---|
| `auto-switch-composition-mode` | Automatically switch to halfwidth | `t` / `nil` | on | With romaji input, switch to halfwidth alphanumeric input when you type `http`, `www.`, `\\`, `google` and the like |
| `use-auto-conversion` | Convert at punctuations | `t` / `nil` | off | Convert the reading typed so far when you type one of the characters below |
| `auto-conversion-key` | Characters that convert | A combination of `"。"` `"、"` `"？"` `"！"` (a list) | 。 ？ ！ | The characters that trigger converting at punctuation; only with `use-auto-conversion` on |
| `shift-key-mode-switch` | Shift key mode switch | `"オフ"` off (0) / `"英数字"` alphanumeric (1) / `"カタカナ"` katakana (2) | alphanumeric | Whether typing a letter with Shift switches to alphanumeric or katakana input |

## Suggest

| Key | Item | Values | Default | Meaning |
|:---|:---|:---|:---|:---|
| `use-history-suggest` | Use input history | `t` / `nil` | on | Suggest words committed before as you start typing |
| `use-dictionary-suggest` | Use system dictionary | `t` / `nil` | on | Suggest dictionary words as you start typing |
| `use-realtime-conversion` | Use realtime conversion | `t` / `nil` | on | Also offer the conversion of the whole reading while typing |
| `suggestions-size` | Maximum number of suggestions | 1 to 9 | 3 | The most suggestions shown while typing |

## Privacy

| Key | Item | Values | Default | Meaning |
|:---|:---|:---|:---|:---|
| `incognito-mode` | Secret mode | `t` / `nil` | off | Temporarily stop personalization, history-based suggestions and the user dictionary |
| `presentation-mode` | Presentation mode | `t` / `nil` | off | Temporarily stop all suggestions while typing |

## Not handled

- Custom keymaps that define each key, the romaji table and the halfwidth/fullwidth rules per
  character group need table editors and are not handled; they are kept as they are in the file
- The usage dictionary, the input mode indicator near the cursor and the Japanese keyboard layout
  option do not take effect in Emacs and are not handled
