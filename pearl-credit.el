;;; pearl-credit.el --- AI API balance in the modeline  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 OverbearingPearl
;; Author: OverbearingPearl <OverbearingPearl@outlook.com>
;; Assisted-by: Kimi:kimi-k2.5
;; URL: https://github.com/OverbearingPearl/pearl-credit
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1"))
;; Keywords: comm, convenience, ai, llm, api, balance, modeline, mode-line, openrouter, deepseek, moonshot
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Display AI API account balances (OpenRouter, DeepSeek, Moonshot)
;; in the mode line.
;; Polls endpoints asynchronously without blocking, and caches results
;; with customizable intervals.
;; Provides visual indicators (Unicode block bars, color-coded
;; thresholds) for low balance warnings.
;;
;; Supports: OpenRouter (USD), DeepSeek (CNY), Moonshot (CNY)
;;
;; Setup: add entries to ~/.authinfo or ~/.authinfo.gpg:
;;
;;   machine openrouter.ai password sk-or-v1-...
;;   machine deepseek.com password sk-...
;;   machine moonshot.cn password sk-...
;;
;; Then enable `pearl-credit-mode' globally.
;;
;; Features:
;; - Automatic polling with configurable interval
;; - Cycle through providers or jump to specific one
;; - Error resilience (shows stale data indicator on fetch failure)
;; - No browser required, pure Emacs Lisp

;;; Code:

(require 'json)
(require 'url)
(require 'url-http)
(require 'cl-lib)
(require 'auth-source)

(defvar url-http-response-status)

(defgroup pearl-credit nil
  "AI API balance in the modeline."
  :group 'external)

(defcustom pearl-credit-poll-interval 300
  "Seconds between automatic balance polls."
  :type 'integer
  :group 'pearl-credit)

(defcustom pearl-credit-timeout 10
  "Seconds to wait for an HTTP response before giving up."
  :type 'integer
  :group 'pearl-credit)

(defcustom pearl-credit-active-providers '(openrouter deepseek moonshot)
  "List of providers to display.
Each element should be a symbol matching those in `pearl-credit--providers'.
Set to nil to display all configured providers."
  :type '(repeat (choice (const openrouter)
                         (const deepseek)
                         (const moonshot)))
  :group 'pearl-credit)

(defvar pearl-credit--providers
  '((openrouter
     :name "openrouter"
     :currency "$"
     :host "openrouter.ai"
     :url "https://openrouter.ai/api/v1/credits"
     :parser pearl-credit--parse-openrouter)
    (deepseek
     :name "deepseek"
     :currency "¥"
     :host "deepseek.com"
     :url "https://api.deepseek.com/user/balance"
     :parser pearl-credit--parse-deepseek)
    (moonshot
     :name "moonshot"
     :currency "¥"
     :host "moonshot.cn"
     :url "https://api.moonshot.cn/v1/users/me/balance"
     :parser pearl-credit--parse-moonshot))
  "Provider specifications.
Each entry is a cons (SYMBOL . PLIST) with :name, :currency,
:host, :url, and :parser.")

(defvar pearl-credit--state (make-hash-table :test 'eq)
  "Maps provider symbols to plists with :balance, :error, and :timestamp.")

(defvar pearl-credit--timer nil
  "Timer for automatic polling.")

(defvar pearl-credit--current-index 0
  "Index of currently displayed provider in `pearl-credit-active-providers'.")

(defvar pearl-credit-mode-string ""
  "String displayed in the mode line.")

(defcustom pearl-credit-low-threshold 1.0
  "Balance threshold below which to highlight as critical (red)."
  :type 'number
  :group 'pearl-credit)

(defcustom pearl-credit-warning-threshold 2.0
  "Balance threshold below which to highlight as warning (orange)."
  :type 'number
  :group 'pearl-credit)

(defface pearl-credit-critical
  '((t :foreground "red"))
  "Face for critical low balance."
  :group 'pearl-credit)

(defface pearl-credit-warning
  '((t :foreground "orange"))
  "Face for warning balance."
  :group 'pearl-credit)

(defface pearl-credit-normal
  '((t :foreground "green"))
  "Face for normal balance."
  :group 'pearl-credit)

(defun pearl-credit--parse-openrouter (data)
  "Extract remaining balance from OpenRouter response DATA."
  ;; Try multiple possible field paths
  (or
   ;; Direct balance field
   (let ((balance (cdr (assoc "balance" data))))
     (when balance
       (if (stringp balance) (string-to-number balance) balance)))
   ;; Credits format
   (let* ((inner (cdr (assoc "data" data)))
          (total (cdr (assoc "total_credits" inner)))
          (used (cdr (assoc "total_usage" inner))))
     (when (and total used)
       (let ((total-num (if (stringp total) (string-to-number total) total))
             (used-num (if (stringp used) (string-to-number used) used)))
         (when (and (numberp total-num) (numberp used-num))
           (- total-num used-num)))))
   ;; Usage format
   (let* ((usage (cdr (assoc "usage" data)))
          (total (cdr (assoc "total_credits" usage)))
          (used (cdr (assoc "total_usage" usage))))
     (when (and total used)
       (let ((total-num (if (stringp total) (string-to-number total) total))
             (used-num (if (stringp used) (string-to-number used) used)))
         (when (and (numberp total-num) (numberp used-num))
           (- total-num used-num)))))))

(defun pearl-credit--parse-deepseek (data)
  "Extract balance from DeepSeek response DATA."
  (or
   ;; Standard balance_infos format
   (let* ((infos (cdr (assoc "balance_infos" data)))
          (first (and (listp infos) (car infos)))
          (total (cdr (assoc "total_balance" first))))
     (when total
       (if (stringp total) (string-to-number total) total)))
   ;; Fallback to a top-level balance field
   (let ((bal (cdr (assoc "balance" data))))
     (when bal
       (if (stringp bal) (string-to-number bal) bal)))))

(defun pearl-credit--parse-moonshot (data)
  "Extract balance from Moonshot response DATA."
  (or
   ;; Standard nested data format
   (let* ((inner (cdr (assoc "data" data)))
          (balance (cdr (assoc "available_balance" inner))))
     (when balance
       (if (stringp balance) (string-to-number balance) balance)))
   ;; Fallback to top-level fields
   (let ((balance (cdr (assoc "available_balance" data))))
     (when balance
       (if (stringp balance) (string-to-number balance) balance)))
   (let ((balance (cdr (assoc "balance" data))))
     (when balance
       (if (stringp balance) (string-to-number balance) balance)))))

(defun pearl-credit--format-tooltip ()
  "Generate tooltip text showing all providers."
  (cl-loop for sym in pearl-credit-active-providers
           for spec = (cdr (assq sym pearl-credit--providers))
           when spec
           for state = (gethash sym pearl-credit--state)
           for currency = (plist-get spec :currency)
           for balance = (plist-get state :balance)
           for err = (plist-get state :error)
           for name = (plist-get spec :name)
           concat (if balance
                      (format "%s%s: %s%.2f%s\n"
                              (pearl-credit--balance-bar balance)
                              name
                              currency
                              balance
                              (if err "~" ""))
                    ;; No balance yet - match modeline placeholder style
                    (format "[░]%s:%s--\n" name currency))
           into lines
           finally return (string-trim-right lines "\n")))

(defun pearl-credit--fetch (provider callback)
  "Fetch balance for PROVIDER, then call CALLBACK.
CALLBACK receives three arguments: PROVIDER, RESULT-TYPE, and VALUE.
RESULT-TYPE is either :ok or :error."
  (let* ((spec (cdr (assq provider pearl-credit--providers)))
         (host (plist-get spec :host))
         (url (plist-get spec :url))
         (auth (car (auth-source-search :host host :require '(:secret)))))
    (if (null auth)
        (funcall callback provider :error 'no-auth)
      (let* ((secret (plist-get auth :secret))
             (api-key (if (functionp secret) (funcall secret) secret))
             (url-request-method "GET")
             (url-request-extra-headers
              `(("Authorization" . ,(concat "Bearer " api-key))))
             (done nil)
             (buf nil)
             (timer nil)
             (finish (lambda (sym type val)
                       (when timer
                         (cancel-timer timer))
                       (setq done t)
                       (when (and buf (buffer-live-p buf))
                         (kill-buffer buf))
                       (funcall callback sym type val))))
        (setq timer
              (run-with-timer pearl-credit-timeout nil
                              (lambda ()
                                (unless done
                                  (funcall finish provider :error 'timeout)))))
        (setq buf
              (url-retrieve
               url
               (lambda (status)
                 (unless done
                   (if (plist-get status :error)
                       (funcall finish provider :error 'http)
                     (let ((http-status url-http-response-status))
                       (if (or (null http-status) (>= http-status 400))
                           (funcall finish provider :error 'http)
                         (goto-char (point-min))
                         (if (search-forward "\n\n" nil t)
                             (let ((json-str (buffer-substring (point) (point-max))))
                               (condition-case nil
                                   (let* ((json-object-type 'alist)
                                          (json-key-type 'string)
                                          (data (json-read-from-string json-str)))
                                     (funcall finish provider :ok data))
                                 (json-error
                                  (funcall finish provider :error 'json))))
                           (funcall finish provider :error 'format)))))))
               nil
               t))
        ;; Prevent "running process" prompt on exit
        (when buf
          (with-current-buffer buf
            (when-let ((proc (get-buffer-process (current-buffer))))
              (set-process-query-on-exit-flag proc nil))))
        (unless buf
          (funcall finish provider :error 'http))))))

(defun pearl-credit--update-state (provider result-type value)
  "Update state for PROVIDER.
RESULT-TYPE is :ok or :error.  VALUE is the balance or error symbol."
  (let* ((old-state (gethash provider pearl-credit--state))
         (old-balance (plist-get old-state :balance)))
    (puthash provider
             (pcase result-type
               (:ok `(:balance ,value :error nil :timestamp ,(current-time)))
               (:error `(:balance ,old-balance :error ,value :timestamp ,(current-time))))
             pearl-credit--state))
  (pearl-credit--update-mode-string))

(defun pearl-credit--balance-bar (balance)
  "Return Unicode block character representing BALANCE relative to 10.0."
  (if (or (null balance) (<= balance 0))
      "[▁]"
    (cond
     ((>= balance 10.0) "[█]")
     ((>= balance 8.75) "[▇]")
     ((>= balance 7.5)  "[▆]")
     ((>= balance 6.25) "[▅]")
     ((>= balance 5.0)  "[▄]")
     ((>= balance 3.75) "[▃]")
     ((>= balance 2.5)  "[▂]")
     (t "[▁]"))))

(defun pearl-credit--update-mode-string ()
  "Rebuild `pearl-credit-mode-string' from current state."
  (if (null pearl-credit-active-providers)
      (setq pearl-credit-mode-string "")
    (let* ((current-sym (nth pearl-credit--current-index pearl-credit-active-providers))
           (spec (cdr (assq current-sym pearl-credit--providers)))
           (state (gethash current-sym pearl-credit--state))
           (balance (plist-get state :balance))
           (err (plist-get state :error))
           (name (plist-get spec :name))
           (currency (plist-get spec :currency)))
      (setq pearl-credit-mode-string
            (if (and spec balance)
                (let ((text (format " %s%s:%s%.2f%s"
                                    (pearl-credit--balance-bar balance)
                                    name
                                    currency
                                    balance
                                    (if err "~" ""))))
                  (cond
                   ((< balance pearl-credit-low-threshold)
                    (propertize text 'face 'pearl-credit-critical))
                   ((< balance pearl-credit-warning-threshold)
                    (propertize text 'face 'pearl-credit-warning))
                   (t
                    (propertize text 'face 'pearl-credit-normal))))
              ;; No balance yet - still show placeholder
              (format " [░]%s:%s--" (or name "?") (or currency "$"))))))
  (force-mode-line-update t))

(defun pearl-credit--poll-all ()
  "Poll all configured providers asynchronously."
  (dolist (provider pearl-credit--providers)
    (pearl-credit--fetch
     (car provider)
     (lambda (sym type val)
       (if (eq type :ok)
           (let* ((spec (cdr (assq sym pearl-credit--providers)))
                  (parser (plist-get spec :parser))
                  (balance (funcall parser val)))
             (if balance
                 (pearl-credit--update-state sym :ok balance)
               (pearl-credit--update-state sym :error 'parse)))
         (pearl-credit--update-state sym type val))))))

(defun pearl-credit-refresh ()
  "Force refresh all balances."
  (interactive)
  (pearl-credit--poll-all))

(defun pearl-credit-cycle ()
  "Cycle to next provider and show current provider balance."
  (interactive)
  (pearl-credit--cycle-provider)
  (message "%s" pearl-credit-mode-string))

(defun pearl-credit--cycle-provider ()
  "Switch to next provider in rotation."
  (setq pearl-credit--current-index
        (mod (1+ pearl-credit--current-index)
             (length pearl-credit-active-providers)))
  (pearl-credit--update-mode-string))

(defun pearl-credit-switch-to-provider (provider)
  "Switch display to a specific PROVIDER.
PROVIDER should be a symbol in `pearl-credit-active-providers'."
  (interactive
   (list (intern
          (completing-read "Provider: "
                           (mapcar #'symbol-name pearl-credit-active-providers)
                           nil t))))
  (let ((idx (cl-position provider pearl-credit-active-providers)))
    (unless idx
      (user-error "Provider %s is not active" provider))
    (setq pearl-credit--current-index idx)
    (pearl-credit--update-mode-string)
    (message "%s" pearl-credit-mode-string)))

(defun pearl-credit-status ()
  "Show all provider balances in minibuffer."
  (interactive)
  (message "%s" (pearl-credit--format-tooltip)))

(define-minor-mode pearl-credit-mode
  "Show AI API balances in the mode line."
  :global t
  :require 'pearl-credit
  ;; Use :eval so any modeline plugin displays us correctly
  :lighter (:eval pearl-credit-mode-string)
  (if pearl-credit-mode
      (progn
        ;; Clean up legacy global-mode-string entries from previous versions
        (setq global-mode-string
              (remove '(:eval pearl-credit-mode-string) global-mode-string))
        (setq pearl-credit--current-index 0)  ; Reset rotation
        (pearl-credit--poll-all)
        (setq pearl-credit--timer
              (run-with-timer pearl-credit-poll-interval
                              pearl-credit-poll-interval
                              #'pearl-credit--poll-all)))
    (when pearl-credit--timer
      (cancel-timer pearl-credit--timer)
      (setq pearl-credit--timer nil))
    ;; Clean up legacy entries
    (setq global-mode-string
          (remove '(:eval pearl-credit-mode-string) global-mode-string))
    (force-mode-line-update t)))

(provide 'pearl-credit)

;;; pearl-credit.el ends here
