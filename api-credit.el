;;; api-credit.el --- AI API balance in the modeline  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 OverbearingPearl
;; Author: OverbearingPearl <OverbearingPearl@outlook.com>
;; Assisted-by: DeepSeek:deepseek-v4-flash, GLM:glm-5.3-flash, Laguna:laguna-s-2.1
;; URL: https://github.com/OverbearingPearl/api-credit
;; Version: 0.1.3
;; Package-Requires: ((emacs "25.1"))
;; Keywords: comm, convenience, ai, llm, api, balance, credits, modeline, mode-line, provider, extensible, universal, balance-monitor, openrouter, deepseek, moonshot, openai, anthropic, gemini, mistral, groq, perplexity, cohere
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Display AI API account balances in the Emacs mode line.  This
;; package is deliberately provider-agnostic: adding support for a new
;; AI API is usually just a few lines added to
;; `api-credit--providers'.
;;
;; Currently bundled providers: OpenRouter (USD), DeepSeek (CNY),
;; Moonshot (CNY).  However the design makes it trivial to add many
;; others - OpenAI, Anthropic, Mistral, Cohere, Gemini, Groq,
;; Perplexity, and any provider that exposes a balance or usage
;; endpoint.
;;
;; If you use a service not listed above, please contribute a
;; provider entry.  Each entry lives in `api-credit--providers' and
;; consists of:
;;
;;   (MY-PROVIDER
;;    :name "My Provider"
;;    :currency "$"
;;    :host  "api.myprovider.com"
;;    :url   "https://api.myprovider.com/v1/credits"
;;    :recharge-url "https://dashboard.myprovider.com/top-up" ; optional
;;    :parser 'api-credit--parse-my-provider)
;;
;; The parser function receives the JSON response (already converted
;; into an alist) and returns the numeric balance.  That is typically
;; all that is required to add a new vendor.
;;
;; Setup: add entries to ~/.authinfo or ~/.authinfo.gpg:
;;
;;   machine openrouter.ai password sk-or-v1-...
;;   machine deepseek.com password sk-...
;;   machine moonshot.cn password sk-...
;;   machine api.myprovider.com password sk-...
;;
;; Then enable `api-credit-mode' globally.
;;
;; Features:
;; - Automatic polling with configurable interval
;; - Cycle through providers or jump to specific one
;; - Error resilience (shows stale data indicator on fetch failure)
;; - No browser required, pure Emacs Lisp
;; - Extensible provider registry (`api-credit--providers')
;;
;; New contributors are welcome.  This package aims to become a
;; universal AI balance monitor, so please help extend it to the APIs
;; you use.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'auth-source)
(require 'url)

(defgroup api-credit nil
  "AI API balance in the modeline."
  :group 'external)

(defcustom api-credit-poll-interval 300
  "Seconds between automatic balance polls."
  :type 'integer
  :group 'api-credit)

(defcustom api-credit-timeout 10
  "Seconds to wait for an HTTP request.
The curl backend passes it to curl as `--max-time'; the url.el
backend enforces it with a timer."
  :type 'integer
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

(defcustom api-credit-default-provider nil
  "Default provider to display on startup.
If nil, start with the first provider in `api-credit-active-providers'.
Otherwise, should be a symbol like `openrouter', `deepseek', or `moonshot'
that exists in `api-credit-active-providers'."
  :type '(choice (const :tag "First active provider" nil)
                 (symbol :tag "Specific provider"))
  :set (lambda (sym val)
         (set-default sym val)
         (let ((idx (and (bound-and-true-p api-credit-mode)
                         (cl-position val api-credit-active-providers))))
           ;; Only re-point the mode line when a valid provider was
           ;; selected.  This also prevents re-evaluating the defcustom
           ;; (e.g. under testcover's eval-buffer) from clobbering a
           ;; provider the user has already chosen.
           (when idx
             (setq api-credit--current-index idx)
             (api-credit--update-mode-string))))
  :group 'api-credit)

(defvar api-credit--url-fallback-announced nil
  "This variable is non-nil once the fallback to `url.el' has been announced.")

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

(defun api-credit--json-parse (str)
  "Parse STR as JSON using alist objects and string keys.
Signals `json-error' on malformed input."
  (let ((json-object-type 'alist)
        (json-key-type 'string))
    (json-read-from-string str)))

(defun api-credit--fetch (provider callback)
  "Fetch balance for PROVIDER, then call CALLBACK.
PROVIDER is a symbol like `openrouter'.
Transport is automatic: when present in variable `exec-path', curl
is used; otherwise the built-in url.el transport is used (announced
once per session).  There is no user option for this.
CALLBACK receives three arguments: PROVIDER, RESULT-TYPE, and VALUE.
RESULT-TYPE is either :ok or :error.
VALUE is either parsed data (for :ok) or error symbol (for :error).
Error symbols can be: `no-auth', `timeout', `curl-failed',
`url-failed', `http', `json', or `format'."
  (let* ((spec (cdr (assq provider api-credit--providers)))
         (host (plist-get spec :host))
         (url (plist-get spec :url))
         (auth (car (auth-source-search :host host :require '(:secret)))))
    (if (null auth)
        (funcall callback provider :error 'no-auth)
      (let* ((secret (plist-get auth :secret))
             (api-key (if (functionp secret) (funcall secret) secret)))
        (if (executable-find "curl")
            (api-credit--fetch-curl provider url api-key callback)
          ;; Degradation point: no curl executable on this system;
          ;; fall back to the built-in url.el backend.
          (unless api-credit--url-fallback-announced
            (message "api-credit: curl not found; using built-in url.el")
            (setq api-credit--url-fallback-announced t))
          (api-credit--fetch-url provider url api-key callback))))))

(defun api-credit--fetch-curl (provider url api-key callback)
  "Fetch URL with the curl executable for PROVIDER, then call CALLBACK.
See `api-credit--fetch' for the CALLBACK protocol."
  (let* ((done nil)
         (process nil)
         (output-buffer (generate-new-buffer " *api-curl-output*"))
         (error-buffer (generate-new-buffer " *api-curl-error*"))
         (finish (lambda (type val)
                   (setq done t)
                   ;; Clean up process tracking
                   (remhash provider api-credit--active-processes)
                   (when (process-live-p process)
                     (delete-process process))
                   (when (buffer-live-p output-buffer)
                     (kill-buffer output-buffer))
                   (when (buffer-live-p error-buffer)
                     (kill-buffer error-buffer))
                   (funcall callback provider type val)))
         (curl-args (list
                     "--silent"
                     "--show-error"
                     "--max-time" (number-to-string api-credit-timeout)
                     "--header" (concat "Authorization: Bearer " api-key)
                     url)))
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
                                     (let ((data (api-credit--json-parse json-str)))
                                       (funcall finish :ok data))
                                   (json-error
                                    (funcall finish :error 'json)))))
                           (funcall finish :error 'http))))
                      ;; curl exit code 28 = CURLE_OPERATION_TIMEDOUT,
                      ;; i.e. --max-time elapsed (see curl(1) man page,
                      ;; EXIT CODES).
                      ((and (string-prefix-p "exited abnormally" event)
                            (= (process-exit-status proc) 28))
                       (funcall finish :error 'timeout))
                      ((or (string-prefix-p "exited abnormally" event)
                           (string-prefix-p "failed" event))
                       (funcall finish :error 'curl-failed))
                      ((string= event "killed\n")
                       ;; Process was killed by timeout or cleanup
                       nil))))
                 :noquery t))
          ;; Track active process
          (puthash provider process api-credit--active-processes))
      (error
       (funcall finish :error 'curl-failed)))))

(defun api-credit--fetch-url (provider url api-key callback)
  "Fetch URL with the built-in url.el backend for PROVIDER.
Then call CALLBACK; see `api-credit--fetch' for the protocol.
url.el has no built-in request timeout, so `api-credit-timeout'
is enforced with a timer that kills the connection."
  (let* ((done nil)
         (buffer nil)
         (timer nil)
         (finish (lambda (type val)
                   (setq done t)
                   (when timer
                     (cancel-timer timer)
                     (setq timer nil))
                   (funcall callback provider type val)))
         (abort (lambda ()
                  ;; Kill the pending connection and its buffer.
                  (let ((proc (and (buffer-live-p buffer)
                                   (get-buffer-process buffer))))
                    (when proc
                      (delete-process proc)))
                  (when (buffer-live-p buffer)
                    (kill-buffer buffer))))
         (handle (lambda (type val)
                   (unless done
                     (funcall abort)
                     (funcall finish type val)))))
    (setq timer
          (run-with-timer api-credit-timeout nil
                          (lambda ()
                            (funcall handle :error 'timeout))))
    (condition-case _
        (setq buffer
              (let ((url-request-method "GET")
                    (url-request-extra-headers
                     `(("Authorization" . ,(concat "Bearer " api-key)))))
                (url-retrieve
                 url
                 (lambda (status)
                   (cond
                    (done)          ; already timed out or finished
                    ((plist-get status :error)
                     ;; Connection-level failure (DNS, refused, TLS).
                     (funcall handle :error 'url-failed))
                    (t
                     (with-current-buffer buffer
                       (goto-char (point-min))
                       (let* ((status-line (buffer-substring
                                            (point)
                                            (progn (end-of-line) (point))))
                              (code (and (string-match
                                          "HTTP/[0-9.]+[ \t]+\\([0-9]+\\)"
                                          status-line)
                                         (string-to-number
                                          (match-string 1 status-line)))))
                         (if (not (and (numberp code)
                                       (>= code 200) (< code 300)))
                             (funcall handle :error 'http)
                           (if (not (re-search-forward "\r?\n\r?\n" nil t))
                               (funcall handle :error 'http)
                             (condition-case nil
                                 (let ((data (api-credit--json-parse
                                              (buffer-substring
                                               (point) (point-max)))))
                                   (funcall handle :ok data))
                               (json-error
                                (funcall handle :error 'json)))))))))))))
      (error
       (funcall handle :error 'url-failed)))))

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

(defun api-credit--mode-start ()
  "Start periodic polling and display for `api-credit-mode'."
  ;; Clean up any pending processes from previous sessions.
  (api-credit--cleanup-processes)
  ;; Clean up legacy global-mode-string entries from previous versions.
  (setq global-mode-string
        (remove '(:eval api-credit-mode-string) global-mode-string))
  ;; Set initial provider: default if valid, otherwise first active.
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

(defun api-credit--mode-stop ()
  "Stop polling and clean up state for `api-credit-mode'."
  (when api-credit--timer
    (cancel-timer api-credit--timer)
    (setq api-credit--timer nil))
  (api-credit--cleanup-processes)
  (setq global-mode-string
        (remove '(:eval api-credit-mode-string) global-mode-string))
  (force-mode-line-update t))

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
      (api-credit--mode-start)
    (api-credit--mode-stop)))

(provide 'api-credit)

;;; api-credit.el ends here
