;;; mozc-config.el --- Mozc の設定を Emacs から変える  -*- lexical-binding: t; -*-

;; Copyright 2026, elecxzy project
;; Use of this source code is governed by the BSD 3-Clause license in LICENSE.

;;; Commentary:

;; Mozc の設定ファイル（%USERPROFILE%\AppData\LocalLow\Mozc\config1.db、
;; helper に --profile_dir で DIR を渡していれば DIR\config1.db）を Emacs Lisp
;; だけで読み書きする。Mozc 公式の設定ダイアログ（Qt の GUI）の代わり。
;;
;;   M-x mozc-config   設定の一覧（RET 変更 / d 既定に戻す / D すべて既定に戻す /
;;                     g 再読込 / q 閉じる）
;;
;; init.el からは `mozc-config-set' で変えられる。
;;
;;   (mozc-config-set 'punctuation-method "，．")
;;   (mozc-config-set 'use-emoji-conversion nil)
;;
;; 設定ファイルは protobuf (mozc.config.Config) をそのまま書き出したもの。
;; mozc-user-dict.el と同じく protobuf を汎用的に読み書きし、ここで扱わない項目
;; （キーマップやローマ字テーブル、半角・全角の規則など）は読んだまま書き戻す。
;; 既定値の項目はファイルから外す（Mozc は書かれていない項目を既定値で補う）。
;; 書き換えたあとは helper を再起動して読み直させる。

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'mozc-user-dict)

(defgroup mozc-config nil
  "Mozc の設定の編集。"
  :group 'mozc)

(defcustom mozc-config-file nil
  "Mozc の設定ファイル。
nil なら helper の学習先（`mozc-helper-program-args' の --profile_dir、
無ければ %USERPROFILE%\\AppData\\LocalLow\\Mozc）の config1.db。"
  :type '(choice (const :tag "helper の学習先" nil) file))

;; 項目は Mozc の設定ダイアログ（gui/config_dialog）のうち、Emacs で効くもの。
;; 用例辞書（helper が用例を落とす）、カーソル周辺の入力モード表示、日本語キー配列は
;; Emacs では効かないので扱わない。
;;   (キー :group 分類 :label 項目名 :field 番号 :type 型 :choices 選択肢 :default 既定値)
;; 型は bool / enum（:choices は (値 . 表示)）/ int（:min :max）/ flags（:choices は
;; (ビット . 表示)）/ preedit（ローマ字・かなと、切替可かどうかの二つのフィールドを一つに見せる）。
(defconst mozc-config-items
  '((preedit-method
     :group "基本設定" :label "ローマ字入力・かな入力" :type preedit :default 0
     :choices ((0 . "ローマ字入力") (1 . "かな入力")
               (2 . "ローマ字入力 (切替可)") (3 . "かな入力 (切替可)")))
    (punctuation-method
     :group "基本設定" :label "句読点" :field 45 :type enum :default 0
     :choices ((0 . "、。") (1 . "，．") (2 . "、．") (3 . "，。")))
    (symbol-method
     :group "基本設定" :label "記号" :field 46 :type enum :default 0
     :choices ((0 . "「」・") (1 . "[]／") (2 . "「」／") (3 . "[]・")))
    (space-character-form
     :group "基本設定" :label "スペースの入力" :field 47 :type enum :default 0
     :choices ((0 . "入力モードに従う") (1 . "全角") (2 . "半角")))
    (selection-shortcut
     :group "基本設定" :label "候補選択ショートカット" :field 52 :type enum :default 1
     :choices ((0 . "なし") (1 . "1 -- 9") (2 . "A -- L")))
    (numpad-character-form
     :group "基本設定" :label "テンキーからの入力" :field 60 :type enum :default 2
     :choices ((0 . "入力モードに従う") (1 . "全角") (2 . "半角") (3 . "直接入力")))
    (yen-sign-character
     :group "基本設定" :label "¥キーで入力する文字" :field 63 :type enum :default 0
     :choices ((0 . "円記号(¥)") (1 . "バックスラッシュ(\\)")))
    (session-keymap
     :group "キー設定" :label "キー設定の選択" :field 41 :type enum :default 2
     ;; カスタム (0) は表を編集できないので選ばせず、設定されていれば表示だけする
     :choices ((1 . "ATOK") (2 . "MS-IME") (3 . "ことえり"))
     :display ((0 . "カスタム") (-1 . "MS-IME")))
    (history-learning-level
     :group "学習" :label "学習機能" :field 50 :type enum :default 0
     :choices ((0 . "有効") (1 . "有効（新規学習はしない）") (2 . "無効")))
    (use-single-kanji-conversion
     :group "特殊変換" :label "単漢字変換" :field 81 :type bool :default t)
    (use-symbol-conversion
     :group "特殊変換" :label "記号変換" :field 82 :type bool :default t)
    (use-emoticon-conversion
     :group "特殊変換" :label "顔文字変換" :field 84 :type bool :default t)
    (use-date-conversion
     :group "特殊変換" :label "日付変換" :field 80 :type bool :default t)
    (use-emoji-conversion
     :group "特殊変換" :label "絵文字変換" :field 89 :type bool :default t)
    (use-number-conversion
     :group "特殊変換" :label "特殊数字変換" :field 83 :type bool :default t)
    (use-calculator
     :group "特殊変換" :label "計算機機能" :field 85 :type bool :default t)
    (use-t13n-conversion
     :group "特殊変換" :label "カタカナ英語変換" :field 86 :type bool :default t)
    (use-zip-code-conversion
     :group "特殊変換" :label "郵便番号変換" :field 87 :type bool :default t)
    (use-spelling-correction
     :group "特殊変換" :label "「もしかして」変換" :field 88 :type bool :default t)
    (auto-switch-composition-mode
     :group "入力補助" :label "自動英数変換を有効にする" :field 56 :type bool :default t)
    (use-auto-conversion
     :group "入力補助" :label "句読点変換を有効にする" :field 61 :type bool :default nil)
    (auto-conversion-key
     :group "入力補助" :label "句読点変換をする文字" :field 62 :type flags :default 13
     :choices ((1 . "。") (2 . "、") (4 . "？") (8 . "！")))
    (shift-key-mode-switch
     :group "入力補助" :label "シフトキーでの入力切替" :field 59 :type enum :default 1
     :choices ((0 . "オフ") (1 . "英数字") (2 . "カタカナ")))
    (use-history-suggest
     :group "サジェスト" :label "入力履歴からのサジェスト自動表示を有効にする"
     :field 100 :type bool :default t)
    (use-dictionary-suggest
     :group "サジェスト" :label "システム辞書からのサジェスト自動表示を有効にする"
     :field 101 :type bool :default t)
    (use-realtime-conversion
     :group "サジェスト" :label "リアルタイム変換を有効にする" :field 102 :type bool :default t)
    (suggestions-size
     :group "サジェスト" :label "サジェストの最大候補数" :field 110 :type int
     :min 1 :max 9 :default 3)
    (incognito-mode
     :group "プライバシー" :label "シークレットモード" :field 20 :type bool :default nil)
    (presentation-mode
     :group "プライバシー" :label "プレゼンテーションモード" :field 23 :type bool :default nil))
  "`mozc-config' で扱う設定の項目。")

;; ---- 設定ファイル ----------------------------------------------------------

(defun mozc-config--file ()
  "設定ファイルの場所。"
  (or mozc-config-file (mozc-user-dict--profile-file "config1.db")))

(defun mozc-config--read ()
  (mozc-user-dict--read-file (mozc-config--file)))

(defun mozc-config--item (key)
  (or (assq key mozc-config-items)
      (error "mozc-config: 知らない項目です: %s" key)))

(defun mozc-config--field (fields num)
  "FIELDS のフィールド NUM の値（varint）。無ければ nil。
protobuf と同じく最後に現れたものを使い、負の int32 / enum は負の数に戻す。"
  (let (v)
    (dolist (f fields)
      (when (and (eq (car f) num) (eq (cadr f) 0))
        (setq v (cddr f))))
    (if (and v (>= v (ash 1 63))) (- v (ash 1 64)) v)))

(defun mozc-config--put (fields num value default)
  "FIELDS のフィールド NUM を VALUE にした並びを返す。DEFAULT と同じならフィールドを外す。"
  (let ((rest (cl-remove-if (lambda (f) (eq (car f) num)) fields)))
    (if (equal value default)
        rest
      (append rest (list (cons num (cons 0 (pcase value ('t 1) ('nil 0) (_ value)))))))))

(defun mozc-config--value (fields item)
  "FIELDS での ITEM の値。書かれていなければ既定値。"
  (let* ((plist (cdr item))
         (default (plist-get plist :default)))
    (pcase (plist-get plist :type)
      ('preedit
       (+ (or (mozc-config--field fields 40) 0)
          (if (eq (mozc-config--field fields 48) 1) 2 0)))
      ('bool
       (let ((v (mozc-config--field fields (plist-get plist :field))))
         (if v (/= v 0) default)))
      (_ (or (mozc-config--field fields (plist-get plist :field)) default)))))

(defun mozc-config--set-value (fields item value)
  "FIELDS の ITEM を VALUE にした並びを返す。"
  (let ((plist (cdr item)))
    (if (eq (plist-get plist :type) 'preedit)
        (mozc-config--put (mozc-config--put fields 40 (% value 2) 0)
                          48 (>= value 2) nil)
      (mozc-config--put fields (plist-get plist :field) value (plist-get plist :default)))))

(defun mozc-config--flag-names (item value)
  "flags の ITEM で、値 VALUE に立っているビットの表示の並び。"
  (mapcar #'cdr (cl-remove-if-not (lambda (c) (/= 0 (logand value (car c))))
                                  (plist-get (cdr item) :choices))))

(defun mozc-config--label (item value)
  "ITEM の値 VALUE の表示。"
  (let ((plist (cdr item)))
    (pcase (plist-get plist :type)
      ('bool (if value "有効" "無効"))
      ('int (number-to-string value))
      ('flags
       (let ((names (mozc-config--flag-names item value)))
         (if names (string-join names " ") "なし")))
      (_ (or (cdr (assq value (plist-get plist :choices)))
             (cdr (assq value (plist-get plist :display)))
             (format "%s" value))))))

(defun mozc-config--value-labels (item)
  "ITEM の値の表示として出うるものの並び（一覧の列の幅を決めるのに使う）。"
  (let ((plist (cdr item)))
    (pcase (plist-get plist :type)
      ('bool (list (mozc-config--label item t) (mozc-config--label item nil)))
      ('int (list (mozc-config--label item (plist-get plist :max))))
      ('flags (list (mozc-config--label item (apply #'logior (mapcar #'car (plist-get plist :choices))))))
      (_ (mapcar #'cdr (append (plist-get plist :choices) (plist-get plist :display)))))))

(defun mozc-config--parse (item value)
  "`mozc-config-set' に渡された VALUE を ITEM の値にする。表示の文字列も受ける。"
  (let* ((plist (cdr item))
         (choices (plist-get plist :choices))
         (bad (lambda () (user-error "mozc-config: %s に %S は設定できません"
                                     (plist-get plist :label) value))))
    (pcase (plist-get plist :type)
      ('bool (pcase value
               ((or 't "有効") t)
               ((or 'nil "無効") nil)
               (_ (funcall bad))))
      ('int (let ((n (if (stringp value) (string-to-number value) value)))
              (unless (and (integerp n) (<= (plist-get plist :min) n (plist-get plist :max)))
                (funcall bad))
              n))
      ('flags
       (cond ((integerp value)
              (unless (zerop (logand value (lognot (apply #'logior (mapcar #'car choices)))))
                (funcall bad))
              value)
             ((listp value)
              (apply #'logior 0 (mapcar (lambda (s) (or (car (rassoc s choices)) (funcall bad)))
                                        value)))
             (t (funcall bad))))
      (_ (cond ((and (integerp value) (assq value choices)) value)
               ((and (stringp value) (rassoc value choices)) (car (rassoc value choices)))
               (t (funcall bad)))))))

(defun mozc-config--write (fields)
  (mozc-user-dict--write-file (mozc-config--file) fields))

;;;###autoload
(defun mozc-config-get (key)
  "設定の項目 KEY（`mozc-config-items' のキー）の今の値を返す。"
  (mozc-config--value (mozc-config--read) (mozc-config--item key)))

;;;###autoload
(defun mozc-config-set (key value)
  "設定の項目 KEY（`mozc-config-items' のキー）を VALUE にし、helper に読み直させる。
VALUE は値そのもの（真偽値・数・選択肢の番号）か、一覧に出る表示の文字列。
句読点変換をする文字は (\"。\" \"？\") のような文字列のリストでもよい。
今の値と同じなら何もしない。"
  (let* ((item (mozc-config--item key))
         (new (mozc-config--parse item value))
         (fields (mozc-config--read)))
    (unless (equal new (mozc-config--value fields item))
      (mozc-config--write (mozc-config--set-value fields item new)))
    new))

;; ---- 一覧 ------------------------------------------------------------------

(defvar mozc-config-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'mozc-config-edit)
    (define-key map "e" #'mozc-config-edit)
    (define-key map "d" #'mozc-config-reset)
    (define-key map "D" #'mozc-config-reset-all)
    map)
  "設定の一覧のキー。")

(define-derived-mode mozc-config-mode tabulated-list-mode "Mozc-Config"
  "Mozc の設定の一覧。
\\<mozc-config-mode-map>\\[mozc-config-edit] 変更 / \\[mozc-config-reset] 既定に戻す / \\[mozc-config-reset-all] すべて既定に戻す / g 再読込 / q 閉じる"
  ;; 列の幅は、全角を 2 桁と数えた表示幅で、いちばん長いものに合わせる
  (let ((width (lambda (head strings) (apply #'max (mapcar #'string-width (cons head strings))))))
    (setq tabulated-list-format
          (vector (list "分類" (funcall width "分類" (mapcar (lambda (it) (plist-get (cdr it) :group))
                                                             mozc-config-items))
                        nil)
                  (list "項目" (funcall width "項目" (mapcar (lambda (it) (plist-get (cdr it) :label))
                                                             mozc-config-items))
                        nil)
                  (list "設定" (funcall width "設定" (mapcan #'mozc-config--value-labels mozc-config-items))
                        nil)
                  '("既定値" 0 nil))))
  (setq tabulated-list-sort-key nil)
  (setq mozc-user-dict--legend
        "RET 変更 / d 既定に戻す / D すべて既定に戻す / g 再読込 / q 閉じる")
  (add-hook 'tabulated-list-revert-hook #'mozc-config--refresh nil t)
  (tabulated-list-init-header))

(defun mozc-config--refresh ()
  (let ((fields (mozc-config--read)))
    (setq tabulated-list-entries
          (mapcar (lambda (item)
                    (let* ((plist (cdr item))
                           (value (mozc-config--value fields item))
                           (default (plist-get plist :default)))
                      (list (car item)
                            (vector (plist-get plist :group)
                                    (plist-get plist :label)
                                    (if (equal value default)
                                        (mozc-config--label item value)
                                      (propertize (mozc-config--label item value)
                                                  'face 'bold))
                                    (propertize (mozc-config--label item default)
                                                'face 'shadow)))))
                  mozc-config-items))))

(defun mozc-config--update-list ()
  "一覧のバッファがあれば、カーソルの位置を保って描き直す。"
  (let ((buf (get-buffer "*Mozc config*")))
    (when buf
      (with-current-buffer buf
        (mozc-config--refresh)
        (tabulated-list-print t)))))

;;;###autoload
(defun mozc-config ()
  "Mozc の設定を一覧し、変更する。"
  (interactive)
  (let ((buf (get-buffer-create "*Mozc config*")))
    (with-current-buffer buf
      (mozc-config-mode)
      (mozc-config--refresh)
      (tabulated-list-print))
    (pop-to-buffer buf)))

(defun mozc-config--current-item ()
  (let ((key (tabulated-list-get-id)))
    (unless key (user-error "項目の行で実行してください"))
    (mozc-config--item key)))

(defun mozc-config--change (item value)
  "ITEM を VALUE にして、一覧とエコーエリアで知らせる。"
  (mozc-config-set (car item) value)
  (mozc-config--update-list)
  (message "%s を「%s」にしました" (plist-get (cdr item) :label)
           (mozc-config--label item value)))

(defun mozc-config-edit ()
  "一覧で、カーソル行の設定を変える。有効・無効の項目は切り替える。"
  (interactive)
  (let* ((item (mozc-config--current-item))
         (plist (cdr item))
         (label (plist-get plist :label))
         (value (mozc-config-get (car item))))
    (mozc-config--change
     item
     (pcase (plist-get plist :type)
       ('bool (not value))
       ('int (let ((min (plist-get plist :min)) (max (plist-get plist :max)) n)
               (while (not (and (integerp n) (<= min n max)))
                 (setq n (read-number (format "%s (%d〜%d): " label min max) value)))
               n))
       ('flags (mozc-config--parse
                item (completing-read-multiple
                      (format "%s（カンマ区切り、空なら無し）: " label)
                      (mapcar #'cdr (plist-get plist :choices)) nil t
                      (string-join (mozc-config--flag-names item value) ","))))
       (_ (let ((names (mapcar #'cdr (plist-get plist :choices))))
            (car (rassoc (completing-read (format "%s: " label) names nil t nil nil
                                          (mozc-config--label item value))
                         (plist-get plist :choices)))))))))

(defun mozc-config-reset ()
  "一覧で、カーソル行の設定を既定値に戻す。"
  (interactive)
  (let ((item (mozc-config--current-item)))
    (mozc-config--change item (plist-get (cdr item) :default))))

(defun mozc-config-reset-all ()
  "一覧のすべての設定を既定値に戻す。一覧に出ない設定（キーマップの表など）はそのまま。"
  (interactive)
  (when (y-or-n-p "一覧のすべての設定を既定値に戻しますか? ")
    (let* ((old (mozc-config--read))
           (fields old))
      (dolist (item mozc-config-items)
        (setq fields (mozc-config--set-value fields item (plist-get (cdr item) :default))))
      (unless (equal fields old)
        (mozc-config--write fields)))
    (mozc-config--update-list)
    (message "すべての設定を既定値に戻しました")))

(provide 'mozc-config)
;;; mozc-config.el ends here
