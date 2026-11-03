;;; mozc-context.el --- Mozc にカーソルの直前の文字列を渡して変換の文脈にする  -*- lexical-binding: t; -*-

;; Copyright 2026, elecxzy project
;; Use of this source code is governed by the BSD 3-Clause license in LICENSE.

;;; Commentary:

;; Mozc は、直前に確定した文節を次の変換の文脈にする（「日本」のあとの
;; 「かい」は「海」、「東京」のあとの「と」は「都」）。ただし文脈になるのは
;; Mozc で確定したものだけで、カーソルを動かすと捨てられる。そのため、
;; 書いてある文章の途中や、ファイルを開いて続きを書くときは文脈が無い。
;;
;; これを読み込むと、変換を始める前にカーソルの直前の文字列（同じ行の
;; `mozc-context-length' 文字まで）を helper に渡す。helper はそれを Mozc の
;; preceding_text として渡し、Mozc は末尾の言葉を読みと品詞つきの文節に
;; 直して文脈にする。mozc.el 本体は変えない。
;;
;;   (require 'mozc)
;;   (require 'mozc-context)
;;
;; 渡すのは、未確定の文字列が無いときにキーを送る直前だけ。直前の文字列を
;; 受け取れない helper（公式の mozc_emacs_helper など）には何も送らない。

;;; Code:

(require 'mozc)

(defgroup mozc-context nil
  "Pass the text before the point to Mozc as the conversion context."
  :group 'mozc)

(defcustom mozc-context-length 20
  "Mozc に渡す、カーソルの直前の文字数の上限。
同じ行の中だけを渡す。0 なら何も渡さず、それまでに渡した文字列も
次のキーで取り消す（Mozc が自分で確定したものだけを文脈にする）。"
  :type 'integer
  :group 'mozc-context)

(defvar-local mozc-context--sent nil
  "このバッファのセッションに直前の文字列を渡したなら non-nil。")

(defun mozc-context--supported-p ()
  "helper が直前の文字列を受け取れるなら non-nil。"
  (mozc-protobuf-get mozc-config-protobuf 'set-context))

(defun mozc-context--preceding-text ()
  "カーソルの直前の、同じ行の `mozc-context-length' 文字まで。"
  (buffer-substring-no-properties
   (max (line-beginning-position) (- (point) mozc-context-length))
   (point)))

(defun mozc-context--clear ()
  "このバッファのセッションに渡した直前の文字列を取り消す。
helper は文字列の無い SetContext を受けると、以後のキーに付けるのをやめる。"
  (when (and mozc-context--sent mozc-session-id
             ;; helper が再起動していれば、渡した文字列はもう無い。
             (eq mozc-session-process (mozc-helper-process)))
    (mozc-session-execute-command 'SetContext))
  (setq mozc-context--sent nil))

(defun mozc-context--send (&rest _)
  "未確定の文字列が無ければ、カーソルの直前の文字列を helper に渡す。
`mozc-send-key-event' の前に呼ばれる。"
  (unless mozc-preedit-in-session-flag
    (if (<= mozc-context-length 0)
        (mozc-context--clear)
      (when (and (mozc-session-create) (mozc-context--supported-p))
        (mozc-session-execute-command 'SetContext
                                      (mozc-context--preceding-text))
        (setq mozc-context--sent t)))))

(advice-add 'mozc-send-key-event :before #'mozc-context--send)

(defun mozc-context-unload-function ()
  "`unload-feature' で advice を外し、各バッファで渡した文字列を取り消す。"
  (advice-remove 'mozc-send-key-event #'mozc-context--send)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (mozc-context--clear)))
  nil)

(provide 'mozc-context)

;;; mozc-context.el ends here
