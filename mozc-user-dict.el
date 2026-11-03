;;; mozc-user-dict.el --- Mozc のユーザー辞書を Emacs から編集する  -*- lexical-binding: t; -*-

;; Copyright 2026, elecxzy project
;; Use of this source code is governed by the BSD 3-Clause license in LICENSE.

;;; Commentary:

;; Mozc のユーザー辞書（%USERPROFILE%\AppData\LocalLow\Mozc\user_dictionary.db、
;; helper に --profile_dir で DIR を渡していれば DIR\user_dictionary.db）を
;; Emacs Lisp だけで読み書きする。Mozc 公式の辞書ツール（Qt の GUI）の代わり。
;;
;;   M-x mozc-user-dict-add     単語を登録（範囲選択中ならその文字列を単語に）
;;   M-x mozc-user-dict-list    一覧（a 登録 / d 削除 / i 取り込み / g 再読込 / q 閉じる）
;;   M-x mozc-user-dict-import  Microsoft IME などのテキスト辞書を取り込む
;;
;; 辞書ファイルは protobuf (mozc.user_dictionary.UserDictionaryStorage) を
;; そのまま書き出したもの。ここでは protobuf を汎用的に読み書きし、知らない
;; 項目も読んだまま書き戻すので、Mozc の版が上がって項目が増えても壊さない。
;; 書き換えたあとは helper を再起動して辞書を読み直させる（mozc.el は helper の
;; 再起動を検知してセッションを作り直す）。

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'ucs-normalize)

(declare-function mozc-helper-process "mozc")
(declare-function mozc-helper-process-stop "mozc")

(defgroup mozc-user-dict nil
  "Mozc のユーザー辞書の編集。"
  :group 'mozc)

(defcustom mozc-user-dict-file nil
  "Mozc のユーザー辞書ファイル。
nil なら helper の学習先（`mozc-helper-program-args' の --profile_dir、
無ければ %USERPROFILE%\\AppData\\LocalLow\\Mozc）の user_dictionary.db。"
  :type '(choice (const :tag "helper の学習先" nil) file))

(defun mozc-user-dict--profile-dir ()
  "helper の引数（`mozc-helper-program-args'）の --profile_dir。無ければ nil。
helper と同じく --profile_dir=DIR も --profile_dir DIR も受け、何度もあれば
最後を使い、`--' より後は見ない。"
  (let ((args (bound-and-true-p mozc-helper-program-args)) dir)
    (while (and args (not (equal (car args) "--")))
      (let ((arg (pop args)))
        (when (and (stringp arg)
                   (string-match "\\`--?profile_dir\\(?:=\\(.*\\)\\)?\\'" arg))
          (setq dir (if (match-beginning 1) (match-string 1 arg) (pop args))))))
    (when (and (stringp dir) (> (length dir) 0))
      ;; helper と同じく絶対パスに限る（`file-name-absolute-p' は ~ も通すので使わない）
      (unless (string-match-p (if (eq system-type 'windows-nt)
                                  "\\`\\(?:[A-Za-z]:\\|[\\/]\\)[\\/]"
                                "\\`/")
                              dir)
        (user-error "mozc-user-dict: --profile_dir は絶対パスで指定してください: %s" dir))
      dir)))

(defun mozc-user-dict--file ()
  "ユーザー辞書ファイルの場所。"
  (or mozc-user-dict-file
      (expand-file-name "user_dictionary.db"
                        (or (mozc-user-dict--profile-dir)
                            (expand-file-name "AppData/LocalLow/Mozc"
                                              (or (getenv "USERPROFILE") "~"))))))

(defcustom mozc-user-dict-name "Emacs"
  "単語を登録する辞書の名前。無ければ作る。"
  :type 'string)

(defconst mozc-user-dict-pos-names
  ["品詞なし" "名詞" "短縮よみ" "サジェストのみ" "固有名詞" "人名" "姓" "名"
   "組織" "地名" "名詞サ変" "名詞形動" "数" "アルファベット" "記号" "顔文字"
   "副詞" "連体詞" "接続詞" "感動詞" "接頭語" "助数詞" "接尾一般" "接尾人名"
   "接尾地名" "動詞ワ行五段" "動詞カ行五段" "動詞サ行五段" "動詞タ行五段"
   "動詞ナ行五段" "動詞マ行五段" "動詞ラ行五段" "動詞ガ行五段" "動詞バ行五段"
   "動詞ハ行四段" "動詞一段" "動詞カ変" "動詞サ変" "動詞ザ変" "動詞ラ変"
   "形容詞" "終助詞" "句読点" "独立語" "抑制単語"]
  "品詞の名前。添字が protobuf の PosType の値（Mozc の user_dictionary_storage.proto）。")

;; Mozc の data/rules/third_party_pos_map.def（Mozc の辞書ツールが取り込みに使う表）から作った。
;; Copyright 2010-2021, Google Inc.（BSD 3-Clause、LICENSE.mozc を参照）
(defconst mozc-user-dict--pos-aliases
  '(("名詞" "副詞的名詞" "その他自立語" "代名詞" "人称代名詞" "指示代名詞"
     "単漢字" "解析不能文字" "短縮語" "1" "41" "普通名詞")
    ("固有名詞" "物品" "固有商品" "固有一般" "7" "8" "その他の固有名詞")
    ("人名" "固有人他" "4")
    ("姓" "固有人姓" "2")
    ("名" "固有人名" "3")
    ("組織" "社名" "建築物" "固有組織" "6")
    ("地名" "地名その他" "国" "県" "郡" "区" "市" "町" "村" "駅" "固有地名" "5")
    ("名詞サ変" "さ変名詞" "ざ変名詞" "名詞ザ変" "9" "10" "サ変名詞")
    ("名詞形動" "形容動詞" "形動名詞" "さ変形動名詞" "さ変形動" "形容動詞ﾉ"
     "形容動詞ﾀﾙ" "形容動詞ｶﾞﾙ" "名サ形動" "形動タリ" "11" "12" "39" "40")
    ("数" "数量" "数詞" "13")
    ("アルファベット" "英字")
    ("顔文字" "顔" "70")
    ("副詞" "さ変副詞" "副詞ﾆ" "副詞ﾅ" "副詞ﾀﾞ" "副詞ﾄ" "副詞ﾄさ変" "14")
    ("連体詞" "指示連体詞" "15")
    ("接続詞" "16")
    ("感動詞" "17")
    ("接頭語" "姓名接頭語" "地名接頭語" "人名接頭語" "固有接頭語" "前置助数詞"
     "丁寧１接頭語" "丁寧２接頭語" "丁寧３接頭語" "冠数詞" "19" "20")
    ("助数詞" "後置助数詞" "後置助数詞＋" "時間助数詞" "時間助数詞＋" "22"
     "数字列接尾語")
    ("接尾一般" "接尾語" "固有接尾語" "社名接尾語" "組織接尾語" "建築物接尾語"
     "連用接尾語" "丁寧接尾語" "丁寧１接尾語" "丁寧２接尾語" "丁寧３接尾語"
     "丁寧４接尾語" "複数接尾語" "21" "組織名接尾語")
    ("接尾人名" "姓名接尾語" "人名接尾語")
    ("接尾地名" "地名接尾語")
    ("動詞ワ行五段" "あわ行五段" "あわ行" "あわ行う音便" "ワ行五段"
     "ワ行五段音便" "31" "43")
    ("動詞カ行五段" "か行五段" "か行" "か行促音便" "カ行五段" "23")
    ("動詞サ行五段" "さ行五段" "さ行" "サ行五段" "25")
    ("動詞タ行五段" "た行五段" "た行" "タ行五段" "26")
    ("動詞ナ行五段" "な行五段" "な行" "ナ行五段" "27")
    ("動詞マ行五段" "ま行五段" "ま行" "マ行五段" "29")
    ("動詞ラ行五段" "ら行五段" "ら行" "ラ行五段" "30")
    ("動詞ガ行五段" "が行五段" "が行" "ガ行五段" "24")
    ("動詞バ行五段" "ば行五段" "ば行" "バ行五段" "28")
    ("動詞ハ行四段" "ハ行四段" "32")
    ("動詞一段" "一段動詞" "33")
    ("動詞カ変" "カ変動詞" "34")
    ("動詞サ変" "サ変動詞" "35")
    ("動詞ザ変" "ザ変動詞" "36")
    ("動詞ラ変" "ら行変格" "ラ変動詞" "45")
    ("形容詞" "形容詞ｶﾞﾙ" "形容詞ｹﾞ" "形容詞ﾒ" "形容詞ｭｳ" "形容詞ｳ"
     "形容詞ウ" "形容詞イ" "形容詞エ" "37" "38" "68" "69")
    ("終助詞" "42")
    ("独立語" "慣用句" "18" "無品詞"))
  "Microsoft IME・ATOK・ことえりなどの品詞名と、それに当たる Mozc の品詞。
各要素は (Mozc の品詞 . 他の IME の品詞名の並び)。")

(defconst mozc-user-dict--pos-unsupported
  '("ナ変動詞" "カ行上二段" "ガ行上二段" "タ行上二段" "ダ行上二段" "ハ行上二段"
    "バ行上二段" "マ行上二段" "ヤ行上二段" "ラ行上二段" "カ行下二段" "ガ行下二段"
    "サ行下二段" "ザ行下二段" "タ行下二段" "ダ行下二段" "ナ行下二段" "ハ行下二段"
    "バ行下二段" "マ行下二段" "ヤ行下二段" "ラ行下二段" "ワ行下二段" "44" "46"
    "47" "48" "49" "50" "51" "52" "53" "54" "55" "56" "57" "58" "59" "60" "61"
    "62" "63" "64" "65" "66" "67")
  "Mozc に当たる品詞が無い、他の IME の品詞名。Mozc の辞書ツールはこの語を取り込まない。")

(defvar mozc-user-dict--import-pos-table nil
  "他の IME の品詞名から Mozc の品詞番号（または `skip'）へのハッシュ表。")

(defun mozc-user-dict--import-pos (name)
  "他の IME の品詞名 NAME に当たる Mozc の品詞番号を返す。
Mozc に当たる品詞が無ければ `skip'、知らない名前なら nil。
Mozc の辞書ツールと同じく、全角英数字と半角カナ、\":ja\" のような言語の指定、
ATOK の自動登録の印（末尾の $ と *）は区別しない。"
  (unless mozc-user-dict--import-pos-table
    (let ((table (make-hash-table :test #'equal)))
      (dotimes (i (length mozc-user-dict-pos-names))
        (puthash (ucs-normalize-NFKC-string (aref mozc-user-dict-pos-names i)) i table))
      (pcase-dolist (`(,mozc . ,names) mozc-user-dict--pos-aliases)
        (let ((pos (cl-position mozc mozc-user-dict-pos-names :test #'equal)))
          (dolist (n names)
            (puthash (ucs-normalize-NFKC-string n) pos table))))
      (dolist (n mozc-user-dict--pos-unsupported)
        (puthash (ucs-normalize-NFKC-string n) 'skip table))
      (setq mozc-user-dict--import-pos-table table)))
  (let ((key (car (split-string (ucs-normalize-NFKC-string name) ":"))))
    (gethash (substring key 0 (string-match "\\*?\\$?\\'" key))
             mozc-user-dict--import-pos-table)))

;; ---- protobuf の読み書き ---------------------------------------------------
;; メッセージは (番号 ワイヤ型 . 値) の並び。値はワイヤ型 0 なら整数、
;; 2 ならバイト列（unibyte 文字列）、1 / 5 なら生の 8 / 4 バイト。

(defun mozc-user-dict--decode (bytes)
  "protobuf のバイト列 BYTES をフィールドの並びにする。"
  (let ((pos 0) (len (length bytes)) fields)
    (cl-flet ((varint ()
                (let ((n 0) (shift 0) b)
                  (while (progn
                           (when (>= pos len) (error "mozc-user-dict: 辞書ファイルが途中で切れています"))
                           (setq b (aref bytes pos) pos (1+ pos))
                           (setq n (logior n (ash (logand b #x7f) shift))
                                 shift (+ shift 7))
                           (>= b #x80)))
                  n)))
      (while (< pos len)
        (let* ((tag (varint))
               (num (ash tag -3))
               (wire (logand tag 7))
               (value (pcase wire
                        (0 (varint))
                        (2 (let ((n (varint)))
                             (prog1 (substring bytes pos (+ pos n))
                               (setq pos (+ pos n)))))
                        (1 (prog1 (substring bytes pos (+ pos 8)) (setq pos (+ pos 8))))
                        (5 (prog1 (substring bytes pos (+ pos 4)) (setq pos (+ pos 4))))
                        (_ (error "mozc-user-dict: 未対応のワイヤ型 %d" wire)))))
          (push (cons num (cons wire value)) fields))))
    (nreverse fields)))

(defun mozc-user-dict--varint (n)
  (let (bytes)
    (while (progn (push (if (>= n #x80) (logior (logand n #x7f) #x80) n) bytes)
                  (setq n (ash n -7))
                  (> n 0)))
    (apply #'unibyte-string (nreverse bytes))))

(defun mozc-user-dict--encode (fields)
  "フィールドの並び FIELDS を protobuf のバイト列にする。"
  (apply #'concat
         (mapcar (lambda (f)
                   (let ((num (car f)) (wire (cadr f)) (value (cddr f)))
                     (concat (mozc-user-dict--varint (logior (ash num 3) wire))
                             (pcase wire
                               (0 (mozc-user-dict--varint value))
                               (2 (concat (mozc-user-dict--varint (length value)) value))
                               (_ value)))))
                 fields)))

(defun mozc-user-dict--get (fields num)
  (cddr (assq num fields)))

(defun mozc-user-dict--get-all (fields num)
  (mapcar #'cddr (cl-remove-if-not (lambda (f) (eq (car f) num)) fields)))

(defun mozc-user-dict--string (fields num)
  (let ((v (mozc-user-dict--get fields num)))
    (if v (decode-coding-string v 'utf-8) "")))

(defun mozc-user-dict--utf8 (s)
  (encode-coding-string s 'utf-8 t))

;; ---- 辞書ファイル ----------------------------------------------------------
;; storage: UserDictionaryStorage のフィールド（2 = dictionaries）
;; 辞書:    UserDictionary（1 = id, 3 = name, 4 = entries）
;; 単語:    Entry（1 = key, 2 = value, 4 = comment, 5 = pos）

(defun mozc-user-dict--read ()
  "辞書ファイルを読んでフィールドの並びを返す。無ければ空。"
  (let ((file (mozc-user-dict--file)))
    (if (file-exists-p file)
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (let ((coding-system-for-read 'no-conversion))
            (insert-file-contents-literally file))
          (mozc-user-dict--decode (buffer-string)))
      nil)))

(defun mozc-user-dict--write (storage)
  "STORAGE を辞書ファイルに書き、helper に読み直させる。"
  (let* ((file (mozc-user-dict--file))
         (tmp (concat file ".tmp"))
         (bytes (mozc-user-dict--encode storage)))
    (make-directory (file-name-directory file) t)
    ;; Mozc 本体と同じく、一時ファイルに書いてから置き換える
    (let ((coding-system-for-write 'no-conversion))
      (write-region bytes nil tmp nil 'silent))
    (rename-file tmp file t))
  (mozc-user-dict-reload))

(defun mozc-user-dict-reload ()
  "helper を再起動して、ユーザー辞書を読み直させる。"
  (interactive)
  (when (and (fboundp 'mozc-helper-process) (mozc-helper-process))
    (mozc-helper-process-stop)))

(defun mozc-user-dict--entry-key (ef)
  "単語のフィールド EF の (よみ 単語 品詞番号)。同じ単語かどうかはこれで決める。"
  (list (mozc-user-dict--string ef 1)
        (mozc-user-dict--string ef 2)
        ;; pos の既定値は名詞 (1)
        (or (mozc-user-dict--get ef 5) 1)))

(defun mozc-user-dict--entries (storage)
  "STORAGE の全単語を (辞書名 よみ 単語 品詞番号 コメント) の並びで返す。"
  (cl-loop for dict in (mozc-user-dict--get-all storage 2)
           for dfields = (mozc-user-dict--decode dict)
           for name = (mozc-user-dict--string dfields 3)
           append (cl-loop for e in (mozc-user-dict--get-all dfields 4)
                           for ef = (mozc-user-dict--decode e)
                           collect `(,name ,@(mozc-user-dict--entry-key ef)
                                           ,(mozc-user-dict--string ef 4)))))

(defun mozc-user-dict--entry-fields (reading word pos comment)
  (append (list (cons 1 (cons 2 (mozc-user-dict--utf8 reading)))
                (cons 2 (cons 2 (mozc-user-dict--utf8 word))))
          (unless (string-empty-p (or comment ""))
            (list (cons 4 (cons 2 (mozc-user-dict--utf8 comment)))))
          (list (cons 5 (cons 0 pos)))))

(defun mozc-user-dict--map-dictionaries (storage fn)
  "STORAGE の各辞書を (FN 辞書のフィールド) で置き換えた STORAGE を返す。
FN が nil を返した辞書はそのまま残す。"
  (mapcar (lambda (f)
            (if (not (eq (car f) 2))
                f
              (let ((new (funcall fn (mozc-user-dict--decode (cddr f)))))
                (if new (cons 2 (cons 2 (mozc-user-dict--encode new))) f))))
          storage))

(defun mozc-user-dict--add-entries (storage entries)
  "STORAGE の `mozc-user-dict-name' 辞書に ENTRIES を足した STORAGE を返す。
ENTRIES は (よみ 単語 品詞番号 コメント) の並び。同じよみ・単語・品詞は足さない。
足した数を cdr に添えて (STORAGE . 足した数) で返す。"
  (let* ((name mozc-user-dict-name)
         (found nil)
         (added 0)
         (add (lambda (dfields)
                ;; 何万語でも線形で済むよう、登録済みの単語はハッシュ表で引き、
                ;; 足す単語は最後にまとめて辞書の後ろに付ける
                (let ((existing (make-hash-table :test #'equal))
                      new-fields)
                  (dolist (e (mozc-user-dict--get-all dfields 4))
                    (puthash (mozc-user-dict--entry-key (mozc-user-dict--decode e)) t existing))
                  (dolist (e entries)
                    (let ((key (list (nth 0 e) (nth 1 e) (nth 2 e))))
                      (unless (gethash key existing)
                        (puthash key t existing)
                        (setq added (1+ added))
                        (push (cons 4 (cons 2 (mozc-user-dict--encode
                                               (apply #'mozc-user-dict--entry-fields e))))
                              new-fields))))
                  (append dfields (nreverse new-fields)))))
         (new (mozc-user-dict--map-dictionaries
               storage
               (lambda (dfields)
                 (when (and (not found)
                            (equal (mozc-user-dict--string dfields 3) name))
                   (setq found t)
                   (funcall add dfields))))))
    (unless found
      (setq new (append new
                        (list (cons 2 (cons 2 (mozc-user-dict--encode
                                               (funcall add
                                                        (list (cons 1 (cons 0 (1+ (random most-positive-fixnum))))
                                                              (cons 3 (cons 2 (mozc-user-dict--utf8 name))))))))))))
    (cons new added)))

;; ---- コマンド --------------------------------------------------------------

(defun mozc-user-dict--read-pos (&optional default)
  (let* ((names (append mozc-user-dict-pos-names nil))
         (default (or default "名詞"))
         (name (completing-read (format "品詞 (既定 %s): " default) names nil t nil nil default)))
    (cl-position name mozc-user-dict-pos-names :test #'equal)))

(defun mozc-user-dict-pos-name (pos)
  (if (and (integerp pos) (< -1 pos (length mozc-user-dict-pos-names)))
      (aref mozc-user-dict-pos-names pos)
    (format "%s" pos)))

;;;###autoload
(defun mozc-user-dict-add (word reading pos &optional comment)
  "単語 WORD をよみ READING・品詞 POS でユーザー辞書に登録する。
範囲を選択していれば、その文字列を単語の既定値にする。
よみの入力中も C-\\ で Mozc を ON にできる。"
  (interactive
   (let* ((sel (and (use-region-p)
                    (buffer-substring-no-properties (region-beginning) (region-end))))
          (word (read-string (if sel (format "単語 (既定 %s): " sel) "単語: ")
                             nil nil sel))
          (reading (read-string (format "「%s」のよみ（ひらがな）: " word)))
          (pos (mozc-user-dict--read-pos))
          (comment (read-string "コメント（省略可）: ")))
     (list word reading pos comment)))
  (when (or (string-empty-p word) (string-empty-p reading))
    (user-error "単語とよみを入れてください"))
  (let ((result (mozc-user-dict--add-entries (mozc-user-dict--read)
                                             (list (list reading word pos comment)))))
    (if (zerop (cdr result))
        (message "「%s」(%s) はもう登録されています" word reading)
      (mozc-user-dict--write (car result))
      (mozc-user-dict--refresh-list)
      (message "「%s」をよみ「%s」(%s) で登録しました" word reading
               (mozc-user-dict-pos-name pos)))))

(defun mozc-user-dict--delete (dict-name reading word pos)
  "辞書 DICT-NAME から、よみ・単語・品詞が一致する単語を消し、消した数を返す。
一つも無ければ辞書ファイルには触らない（helper も再起動しない）。"
  (let* ((key (list reading word pos))
         (deleted 0)
         (storage
          (mozc-user-dict--map-dictionaries
           (mozc-user-dict--read)
           (lambda (dfields)
             (when (equal (mozc-user-dict--string dfields 3) dict-name)
               (cl-remove-if (lambda (f)
                               (and (eq (car f) 4)
                                    (equal (mozc-user-dict--entry-key
                                            (mozc-user-dict--decode (cddr f)))
                                           key)
                                    (cl-incf deleted)))
                             dfields))))))
    (unless (zerop deleted)
      (mozc-user-dict--write storage))
    deleted))

;;;###autoload
(defun mozc-user-dict-import (file &optional pos)
  "テキスト辞書 FILE を取り込む。
1 行 1 語で「よみ<TAB>単語<TAB>品詞<TAB>コメント」（品詞とコメントは省略可）。
Microsoft IME の「テキストファイルで出力」の形式（UTF-16、! で始まる行は
コメント）もそのまま読める。他の IME の品詞名は Mozc の辞書ツールと同じ表で
Mozc の品詞に読み替え、Mozc に当たる品詞が無い語（文語の二段活用など）は
取り込まない。知らない品詞名なら POS（既定は名詞）にする。"
  (interactive (list (read-file-name "取り込むテキスト辞書: " nil nil t)))
  (let ((default-pos (or pos 1))
        entries unknown skipped)
    (with-temp-buffer
      (insert-file-contents file)    ; UTF-16 / UTF-8 / Shift_JIS は自動判別
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (string-trim-right
                     (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))
          (unless (or (string-empty-p line) (string-prefix-p "!" line))
            (let* ((cols (split-string line "\t"))
                   (reading (nth 0 cols))
                   (word (nth 1 cols))
                   (pos-name (nth 2 cols))
                   (p (and pos-name (not (string-empty-p pos-name))
                           (mozc-user-dict--import-pos pos-name))))
              (when (and reading word (not (string-empty-p reading)) (not (string-empty-p word)))
                (cond
                 ((eq p 'skip)
                  (push pos-name skipped))
                 (t
                  (when (and pos-name (not p) (not (string-empty-p pos-name)))
                    (cl-pushnew pos-name unknown :test #'equal))
                  (push (list reading word (or p default-pos) (or (nth 3 cols) "")) entries)))))))
        (forward-line 1)))
    (when (null entries)
      (user-error "取り込める単語がありません: %s" file))
    (setq entries (nreverse entries))
    (let ((result (mozc-user-dict--add-entries (mozc-user-dict--read) entries)))
      (unless (zerop (cdr result))
        (mozc-user-dict--write (car result))
        (mozc-user-dict--refresh-list))
      (message "%d 語を取り込みました（%d 語は登録済み）%s%s"
               (cdr result) (- (length entries) (cdr result))
               (if unknown
                   (format "。知らない品詞は%sにしました: %s"
                           (mozc-user-dict-pos-name default-pos)
                           (string-join (nreverse unknown) " "))
                 "")
               (if skipped
                   (format "。Mozc に無い品詞の %d 語は取り込みませんでした: %s"
                           (length skipped)
                           (string-join (delete-dups (nreverse skipped)) " "))
                 "")))))

;; ---- 一覧 ------------------------------------------------------------------

(defun mozc-user-dict--refresh-list ()
  "一覧のバッファがあれば描き直す。"
  (let ((buf (get-buffer "*Mozc user dictionary*")))
    (when buf
      (with-current-buffer buf (revert-buffer)))))

(defvar mozc-user-dict-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "a" #'mozc-user-dict-add)
    (define-key map "d" #'mozc-user-dict-list-delete)
    (define-key map "i" #'mozc-user-dict-import)
    map)
  "一覧のキー。")

(defconst mozc-user-dict--legend "a 登録 / d 削除 / i 取り込み / g 再読込 / q 閉じる"
  "一覧の下に出すキーの凡例。")

(defun mozc-user-dict--print-with-legend (orig &rest args)
  "`tabulated-list-print' の前後で、一覧の下のキーの凡例を外して付け直す。
再読込・並べ替え・登録や削除後の更新のどれで描き直しても凡例が残るようにする。"
  (if (not (derived-mode-p 'mozc-user-dict-list-mode))
      (apply orig args)
    (let ((inhibit-read-only t))
      (let ((start (text-property-any (point-min) (point-max) 'mozc-user-dict-legend t)))
        (when start (delete-region start (point-max))))
      (prog1 (apply orig args)
        (save-excursion
          (goto-char (point-max))
          (insert (propertize (concat "\n" mozc-user-dict--legend "\n")
                              'face 'shadow 'mozc-user-dict-legend t)))))))

(advice-add 'tabulated-list-print :around #'mozc-user-dict--print-with-legend)

(define-derived-mode mozc-user-dict-list-mode tabulated-list-mode "Mozc-Dict"
  "Mozc のユーザー辞書の一覧。
\\<mozc-user-dict-list-mode-map>\\[mozc-user-dict-add] 登録 / \\[mozc-user-dict-list-delete] 削除 / \\[mozc-user-dict-import] 取り込み / g 再読込 / q 閉じる"
  (setq tabulated-list-format [("よみ" 16 t) ("単語" 20 t) ("品詞" 12 t)
                               ("辞書" 10 t) ("コメント" 0 nil)])
  (setq tabulated-list-sort-key '("よみ" . nil))
  (add-hook 'tabulated-list-revert-hook #'mozc-user-dict--refresh nil t)
  (tabulated-list-init-header))

(defun mozc-user-dict--refresh ()
  (setq tabulated-list-entries
        (mapcar (lambda (e)
                  (pcase-let ((`(,dict ,reading ,word ,pos ,comment) e))
                    (list e (vector reading word (mozc-user-dict-pos-name pos) dict comment))))
                (mozc-user-dict--entries (mozc-user-dict--read)))))

;;;###autoload
(defun mozc-user-dict-list ()
  "ユーザー辞書の単語を一覧する。"
  (interactive)
  (with-current-buffer (get-buffer-create "*Mozc user dictionary*")
    (mozc-user-dict-list-mode)
    (mozc-user-dict--refresh)
    (tabulated-list-print)
    (pop-to-buffer (current-buffer))))

(defun mozc-user-dict-list-delete ()
  "一覧で、カーソル行の単語を消す。"
  (interactive)
  (pcase-let ((`(,dict ,reading ,word ,pos ,_comment) (tabulated-list-get-id)))
    (unless reading (user-error "単語の行で実行してください"))
    (when (y-or-n-p (format "「%s」(%s) を消しますか? " word reading))
      (let ((deleted (mozc-user-dict--delete dict reading word pos)))
        (revert-buffer)
        (pcase deleted
          (0 (message "「%s」は辞書にもうありませんでした（一覧を読み直しました）" word))
          (1 (message "「%s」を消しました" word))
          (_ (message "「%s」を消しました（よみ・品詞も同じ %d 語）" word deleted)))))))

(provide 'mozc-user-dict)
;;; mozc-user-dict.el ends here
