;;; api-credit.el --- AI API balance in the modeline  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 OverbearingPearl
;; Author: OverbearingPearl <OverbearingPearl@outlook.com>
;; Assisted-by: Kimi:kimi-k2.5
;; URL: https://github.com/OverbearingPearl/api-credit
;; Version: 0.1.3
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
;; Then enable `api-credit-mode' globally.
;;
;; Features:
;; - Automatic polling with configurable interval
;; - Cycle through providers or jump to specific one
;; - Error resilience (shows stale data indicator on fetch failure)
;; - No browser required, pure Emacs Lisp

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'auth-source)

(defgroup api-credit nil
  "AI API balance in the modeline."
  :group 'external)

(defcustom api-credit-poll-interval 300
  "Seconds between automatic balance polls."
  :type 'integer
  :group 'api-credit)

(defcustom api-credit-timeout 10
  "Seconds to wait for an HTTP response before giving up."
  :type 'integer
  :group 'api-credit)

(defcustom api-credit-default-provider nil
  "Default provider to display on startup.
If nil, start with the first provider in `api-credit-active-providers'.
Otherwise, should be a symbol like `openrouter', `deepseek', or `moonshot'
that exists in `api-credit-active-providers'."
  :type '(choice (const :tag "First active provider" nil)
                 (symbol :tag "Specific provider"))
  :group 'api-credit)

(defcustom api-credit-active-providers '(openrouter deepseek moonshot)
  "List of providers to display.
Each element should be a symbol matching those in `api-credit--providers'.
Set to nil to display all configured providers."
  :type '(repeat (choice (const openrouter)
                         (const deepseek)
                         (const moonshot)))
  :group 'api-credit)

(defvar api-credit--providers
  '((openrouter
     :name "openrouter"
     :currency "$"
     :host "openrouter.ai"
     :url "https://openrouter.ai/api/v1/credits"
     :recharge-url "https://openrouter.ai/credits"
     :parser api-credit--parse-openrouter)
    (deepseek
     :name "deepseek"
     :currency "¥"
     :host "deepseek.com"
     :url "https://api.deepseek.com/user/balance"
     :recharge-url "https://platform.deepseek.com/"
     :parser api-credit--parse-deepseek)
    (moonshot
     :name "moonshot"
     :currency "¥"
     :host "moonshot.cn"
     :url "https://api.moonshot.cn/v1/users/me/balance"
     :recharge-url "https://platform.moonshot.cn/"
     :parser api-credit--parse-moonshot))
  "Provider specifications.
Each entry is a cons (SYMBOL . PLIST) with :name, :currency,
:host, :url, :recharge-url, and :parser.")

(defvar api-credit--state (make-hash-table :test 'eq)
  "Maps provider symbols to plists with :balance, :error, and :timestamp.")

(defvar api-credit--timer nil
  "Timer for automatic polling.")

(defvar api-credit--active-processes (make-hash-table :test 'eq)
  "Hash table mapping provider symbols to their active curl processes.")

(defvar api-credit--current-index 0
  "Index of currently displayed provider in `api-credit-active-providers'.")

(defvar api-credit-mode-string ""
  "String displayed in the mode line.")

(defun api-credit--parse-openrouter (data)
  "Extract remaining balance from OpenRouter response DATA.
DATA is an alist parsed from JSON response.
Returns balance as a number, or nil if parsing fails."
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

(defun api-credit--parse-deepseek (data)
  "Extract balance from DeepSeek response DATA.
DATA is an alist parsed from JSON response.
Returns balance as a number, or nil if parsing fails."
  (or
   ;; Standard balance_infos format
   (let* ((infos (cdr (assoc "balance_infos" data)))
          (first (and (vectorp infos) (aref infos 0)))
          (total (cdr (assoc "total_balance" first))))
    (when total
      (if (stringp total) (string-to-number total) total)))
   ;; Fallback to a top-level balance field
   (let ((bal (cdr (assoc "balance" data))))
    (when bal
      (if (stringp bal) (string-to-number bal) bal)))))

(defun api-credit--parse-moonshot (data)
  "Extract balance from Moonshot response DATA.
DATA is an alist parsed from JSON response.
Returns balance as a number, or nil if parsing fails."
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

(defun api-credit--format-tooltip ()
  "Generate tooltip text showing all providers.
Returns a string with each provider's name, currency, and balance.
Providers with no balance yet show '--'."
  (cl-loop for sym in api-credit-active-providers
           for spec = (cdr (assq sym api-credit--providers))
           when spec
           for state = (gethash sym api-credit--state)
           for currency = (plist-get spec :currency)
           for balance = (plist-get state :balance)
           for err = (plist-get state :error)
           for name = (plist-get spec :name)
           concat (if balance
                      (format "%s: %s%.2f%s\n"
                              name
                              currency
                              balance
                              (if err "~" ""))
                    ;; No balance yet
                    (format "%s: %s--\n" name currency))
           into lines
           finally return (string-trim-right lines "\n")))

(defun api-credit--fetch (provider callback)
  "Fetch balance for PROVIDER using curl, then call CALLBACK.
PROVIDER is a symbol like `openrouter'.
CALLBACK receives three arguments: PROVIDER, RESULT-TYPE, and VALUE.
RESULT-TYPE is either :ok or :error.
VALUE is either parsed data (for :ok) or error symbol (for :error).
Error symbols can be: `no-auth', `timeout', `curl-failed', `http',
`json', or `format'."
  (let* ((spec (cdr (assq provider api-credit--providers)))
         (host (plist-get spec :host))
         (url (plist-get spec :url))
         (auth (car (auth-source-search :host host :require '(:secret))))
         (done nil)
         (timer nil)
         (process nil)
         (output-buffer (generate-new-buffer " *api-curl-output*"))
         (error-buffer (generate-new-buffer " *api-curl-error*"))
         (finish (lambda (sym type val)
                   (when timer
                     (cancel-timer timer))
                   (setq done t)
                   ;; Clean up process tracking
                   (remhash sym api-credit--active-processes)
                   (when (process-live-p process)
                     (delete-process process))
                   (when (buffer-live-p output-buffer)
                     (kill-buffer output-buffer))
                   (when (buffer-live-p error-buffer)
                     (kill-buffer error-buffer))
                   (funcall callback sym type val))))

    (if (null auth)
        (funcall callback provider :error 'no-auth)
      (let* ((secret (plist-get auth :secret))
             (api-key (if (functionp secret) (funcall secret) secret))
             (curl-args (list
                         "--silent"
                         "--show-error"
                         "--max-time" (number-to-string api-credit-timeout)
                         "--header" (concat "Authorization: Bearer " api-key)
                         url)))

        ;; Set timeout timer
        (setq timer
              (run-with-timer api-credit-timeout nil
                              (lambda ()
                                (unless done
                                  (funcall finish provider :error 'timeout)))))

        ;; Start curl process
        (condition-case _
            (progn
              (setq process
                    (make-process
                     :name (format "api-curl-%s" provider)
                     :buffer output-buffer
                     :stderr error-buffer
                     :command (cons "curl" curl-args)
                     :sentinel
                     (lambda (proc event)
                       (unless done
                         (cond
                          ((string= event "finished\n")
                           (let ((exit-status (process-exit-status proc)))
                             (if (= exit-status 0)
                                 (with-current-buffer output-buffer
                                   (let ((json-str (buffer-string)))
                                     (condition-case nil
                                         (let* ((json-object-type 'alist)
                                                (json-key-type 'string)
                                                (data (json-read-from-string json-str)))
                                           (funcall finish provider :ok data))
                                       (json-error
                                        (funcall finish provider :error 'json)))))
                               (funcall finish provider :error 'http))))
                          ((or (string-prefix-p "exited abnormally" event)
                               (string-prefix-p "failed" event))
                           (funcall finish provider :error 'curl-failed))
                          ((string= event "killed\n")
                           ;; Process was killed by timeout or cleanup
                           nil))))
                     :noquery t))

              ;; Track active process
              (puthash provider process api-credit--active-processes))

          (error
           (funcall finish provider :error 'curl-failed)))))))

(defun api-credit--cleanup-processes ()
  "Clean up all pending curl processes created by api-credit.
Only cleans up processes that were tracked in `api-credit--active-processes'."
  (maphash (lambda (provider proc)
             (when (process-live-p proc)
               (delete-process proc))
             (remhash provider api-credit--active-processes))
           api-credit--active-processes))

(defun api-credit--update-state (provider result-type value)
  "Update state for PROVIDER.
PROVIDER is a symbol like `openrouter'.
RESULT-TYPE is :ok or :error.
VALUE is the balance (for :ok) or error symbol (for :error).
Updates `api-credit--state' hash table and refreshes mode line."
  (let* ((old-state (gethash provider api-credit--state))
         (old-balance (plist-get old-state :balance)))
    (puthash provider
             (pcase result-type
               (:ok `(:balance ,value :error nil :timestamp ,(current-time)))
               (:error `(:balance ,old-balance :error ,value :timestamp ,(current-time))))
             api-credit--state))
  (api-credit--update-mode-string))

(defun api-credit--balance-bar (balance)
  "Return 3‑character Unicode bar representing BALANCE relative to 10.0.
Uses U+25AE (BLACK VERTICAL RECTANGLE) for filled,
U+25AF (WHITE VERTICAL RECTANGLE) for empty.
BALANCE can be nil or a number.
Returns string like \"[   ]\", \"[▯▯▯]\", \"[▮▯▯]\", etc."
  (cond
   ((or (null balance) (<= balance 0)) "[   ]")
   ((<= balance 1.0) "[▯▯▯]")
   ((<= balance 2.0) "[▮▯▯]")
   ((<= balance 10.0) "[▮▮▯]")
   (t "[▮▮▮]")))

(defun api-credit--update-mode-string ()
  "Rebuild `api-credit-mode-string' from current state.
Updates the mode line display based on current provider and balance."
  (if (null api-credit-active-providers)
      (setq api-credit-mode-string "")
    (let* ((current-sym (nth api-credit--current-index api-credit-active-providers))
           (spec (cdr (assq current-sym api-credit--providers)))
           (state (gethash current-sym api-credit--state))
           (balance (plist-get state :balance))
           (name (plist-get spec :name))
           (currency (plist-get spec :currency)))
      (setq api-credit-mode-string
            (if (and spec balance)
                (let ((err (plist-get state :error)))
                  (format " %s%s%.2f%s(%s)"
                          (api-credit--balance-bar balance)
                          currency
                          balance
                          (if err "~" "")
                          name))
              ;; No balance yet - still show placeholder
              (format " [   ]%s--(%s)" (or currency "$") (or name "?"))))))
  (force-mode-line-update t))

(defun api-credit--poll-all ()
  "Poll all configured providers asynchronously.
Initiates fetch requests for each provider in `api-credit--providers'."
  (dolist (provider api-credit--providers)
    (api-credit--fetch
     (car provider)
     (lambda (sym type val)
       (if (eq type :ok)
           (let* ((spec (cdr (assq sym api-credit--providers)))
                  (parser (plist-get spec :parser))
                  (balance (funcall parser val)))
             (if balance
                 (api-credit--update-state sym :ok balance)
               (api-credit--update-state sym :error 'parse)))
         (api-credit--update-state sym type val))))))

(defun api-credit-refresh ()
  "Force refresh all balances.
Interactive command that triggers immediate polling of all providers."
  (interactive)
  (api-credit--poll-all))

(defun api-credit-cycle ()
  "Cycle to next provider and show current provider balance.
Interactive command that rotates display to next provider in list."
  (interactive)
  (api-credit--cycle-provider)
  (message "%s" api-credit-mode-string))

(defun api-credit--cycle-provider ()
  "Switch to next provider in rotation.
Updates `api-credit--current-index' and refreshes mode line."
  (setq api-credit--current-index
        (mod (1+ api-credit--current-index)
             (length api-credit-active-providers)))
  (api-credit--update-mode-string))

(defun api-credit-switch-to-provider (provider)
  "Switch display to a specific PROVIDER.
PROVIDER should be a symbol in `api-credit-active-providers'.
Interactive command with completion."
  (interactive
   (list (intern
          (completing-read "Provider: "
                           (mapcar #'symbol-name api-credit-active-providers)
                           nil t))))
  (let ((idx (cl-position provider api-credit-active-providers)))
    (unless idx
      (user-error "Provider %s is not active" provider))
    (setq api-credit--current-index idx)
    (api-credit--update-mode-string)
    (message "%s" api-credit-mode-string)))

(defun api-credit-recharge-current ()
  "Open browser to recharge page of currently displayed provider.
Interactive command that opens recharge URL in default browser."
  (interactive)
  (if (null api-credit-active-providers)
      (user-error "No active providers")
    (let* ((current-sym (nth api-credit--current-index api-credit-active-providers))
           (spec (cdr (assq current-sym api-credit--providers)))
           (url (plist-get spec :recharge-url)))
      (unless url
        (user-error "No recharge URL configured for %s" (plist-get spec :name)))
      (browse-url url)
      (message "Opening recharge page for %s..." (plist-get spec :name)))))

(defun api-credit-status ()
  "Show all provider balances in minibuffer.
Interactive command that displays formatted tooltip in minibuffer."
  (interactive)
  (message "%s" (api-credit--format-tooltip)))

(define-minor-mode api-credit-mode
  "Show AI API balances in the mode line.
Global minor mode that displays balances and polls periodically.
When enabled, starts polling with `api-credit-poll-interval'.
When disabled, stops polling and cleans up resources."
  :global t
  :require 'api-credit
  ;; Use :eval so any modeline plugin displays us correctly
  :lighter (:eval api-credit-mode-string)
  (if api-credit-mode
      (progn
        ;; Clean up any pending processes from previous sessions
        (api-credit--cleanup-processes)
        ;; Clean up legacy global-mode-string entries from previous versions
        (setq global-mode-string
              (remove '(:eval api-credit-mode-string) global-mode-string))
        ;; Set initial provider: default if valid, otherwise first active
        (setq api-credit--current-index
              (or (and api-credit-default-provider
                       (cl-position api-credit-default-provider
                                    api-credit-active-providers))
                  0))
        (api-credit--poll-all)
        (setq api-credit--timer
              (run-with-timer api-credit-poll-interval
                              api-credit-poll-interval
                              #'api-credit--poll-all)))
    (when api-credit--timer
      (cancel-timer api-credit--timer)
      (setq api-credit--timer nil))
    ;; Clean up pending processes
    (api-credit--cleanup-processes)
    ;; Clean up legacy entries
    (setq global-mode-string
          (remove '(:eval api-credit-mode-string) global-mode-string))
    (force-mode-line-update t)))

(provide 'api-credit)

;;; api-credit.el ends here
