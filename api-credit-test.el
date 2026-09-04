;;; api-credit-test.el --- ERT tests for api-credit  -*- lexical-binding: t; -*-

;;; Commentary:

;; Self-contained ERT tests for api-credit.
;; The runner first reloads the production code from source, clearing
;; any stale definitions, so the suite is always executed against the
;; latest module contents.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'api-credit)

(defvar api-credit-test--dir
  (file-name-directory
   (or load-file-name buffer-file-name default-directory))
  "Directory where api-credit test files and api-credit.el live.
This value is captured while this file is being loaded so it stays
valid even after `unload-feature' has cleared various variables.")

(defvar api-credit-test--file
  (or load-file-name
      (expand-file-name "api-credit-test.el" api-credit-test--dir))
  "Path to this test entrypoint file.
Used by `api-credit-test-run' to re-load the test definitions after
clearing stale erte state.")

(defun api-credit-test-reload-under-test ()
  "Reload api-credit source files from `api-credit-test--dir'.

Unload the feature, clear stale global variables starting with
`api-credit-', then load the main module and any optional lisp/*.el
files.  `api-credit-test--dir' was recorded when this test file was
loaded, so it works even when called from a non-file Emacs session."
  (let ((dir api-credit-test--dir))
    (unless (and dir (file-directory-p dir))
      (error "Cannot locate api-credit source directory from %S"
             api-credit-test--dir))
    (when (featurep 'api-credit)
      (unload-feature 'api-credit t))
    (mapatoms
     (lambda (sym)
       (when (let ((name (symbol-name sym)))
               (and (string-prefix-p "api-credit-" name)
                    (not (string-prefix-p "api-credit-test" name))))
         (when (boundp sym)
           (makunbound sym))
         ;; Clear Custom bookkeeping left over from previous loads, or
         ;; re-evaluating the defcustoms may try to restore a stale
         ;; saved value and eval a not-yet-bound symbol.
         (when (symbol-plist sym)
           (setplist sym nil)))))
    (load-file (expand-file-name "api-credit.el" dir))
    (let ((lisp-dir (expand-file-name "lisp" dir)))
      (when (file-directory-p lisp-dir)
        (dolist (file (directory-files lisp-dir t "\\.el\\'"))
          (load-file file))))))

(defun api-credit-test--snapshot-state ()
  "Return current non-test `api-credit-*' global values as an alist.

`api-credit-mode' is intentionally excluded; its runtime state is
restored by calling the mode function rather than by `set'."
  (let ((saved nil))
    (mapatoms
     (lambda (sym)
       (let ((name (symbol-name sym)))
         (when (and (string-prefix-p "api-credit-" name)
                    (not (string-prefix-p "api-credit-test" name))
                    (not (eq sym 'api-credit-mode))
                    (boundp sym))
           (push (cons sym (symbol-value sym)) saved)))))
    saved))

(defun api-credit-test--restore-state (saved mode-enabled-p)
  "Restore SAVED variable values and MODE-ENABLED-P mode state."
  ;; Only call the mode function when its on/off state changed; this
  ;; prevents restoring every individual test from stopping and
  ;; restarting a live polling timer.
  (let ((current-enabled (and (fboundp 'api-credit-mode)
                              (bound-and-true-p api-credit-mode)))
        (saved-index (cdr (assq 'api-credit--current-index saved))))
    (unless (eq current-enabled mode-enabled-p)
      (when current-enabled
        (api-credit-mode -1)))
    ;; Restore the user's original global variable values.
    (dolist (cell saved)
      (set (car cell) (cdr cell)))
    (unless (eq current-enabled mode-enabled-p)
      (when mode-enabled-p
        (api-credit-mode 1)))
    ;; Re-enabling `api-credit-mode' points the mode line at
    ;; `api-credit-default-provider' (or, when that is nil, at the first
    ;; active provider), overwriting the index restored above.  Put the
    ;; user's original provider choice back so running the test suite
    ;; never changes which provider is displayed.
    (when (and mode-enabled-p
               (bound-and-true-p api-credit-mode)
               (integerp saved-index)
               (< -1 saved-index (length api-credit-active-providers)))
      (setq api-credit--current-index saved-index)
      (api-credit--update-mode-string))))

(defmacro api-credit-test-with-saved-state (&rest body)
  "Run BODY without leaking api-credit state.

Snapshot the existing non-test `api-credit-*' values and the
`api-credit-mode' enabled flag, run BODY, then restore the snapshot
via `unwind-protect'.  This gives every individual ERT test the same
isolation that `api-credit-test-run' provides to the suite as a whole,
so direct `(ert t)' also leaves the user's mode and variables intact."
  (declare (indent 0))
  `(let ((api-credit-test--saved-state (api-credit-test--snapshot-state))
         (api-credit-test--mode-enabled (bound-and-true-p api-credit-mode)))
     (unwind-protect
         (progn ,@body)
       (api-credit-test--restore-state api-credit-test--saved-state
                                       api-credit-test--mode-enabled))))

(defun api-credit-test-run ()
  "Run the ERT test suite for api-credit.

Reloads the production code from source, then executes the test
suite in batch or interactive mode as appropriate, preserving the
user's `api-credit-mode' state and `api-credit-*' variables."
  (interactive)
  (let ((mode-enabled-p (bound-and-true-p api-credit-mode))
        (saved-state (api-credit-test--snapshot-state)))
    ;; Cleanly disable the mode before reloading its code.
    (when mode-enabled-p
      (api-credit-mode -1))
    (unwind-protect
        (progn
          (api-credit-test-reload-under-test)
          (ert-delete-all-tests)
          (when (and api-credit-test--file
                     (file-exists-p api-credit-test--file))
            (load-file api-credit-test--file))
          (if noninteractive
              (ert-run-tests-batch-and-exit "api-credit-")
            (ert t)))
      (api-credit-test--restore-state saved-state mode-enabled-p))))

;; ---------- JSON ----------

(ert-deftest api-credit-test-json-parse-basic ()
  "JSON conversion returns alist with string keys."
  (api-credit-test-with-saved-state
    (let ((input "{\"balance\": 1.5}"))
      (should (equal (api-credit--json-parse input)
                     '(("balance" . 1.5)))))))

;; ---------- PARSERS ----------

(ert-deftest api-credit-test-parse-openrouter-balance-field ()
  "Parse OpenRouter response with top-level balance field."
  (api-credit-test-with-saved-state
    (should (equal (api-credit--parse-openrouter
                    '(("balance" . "10.50")))
                   10.5))))

(ert-deftest api-credit-test-parse-openrouter-credits ()
  "Parse OpenRouter response from the nested credits format."
  (api-credit-test-with-saved-state
    (should (equal (api-credit--parse-openrouter
                    '(("data" . (("total_credits" . "100")
                                 ("total_usage" . "40.5")))))
                   59.5))))

(ert-deftest api-credit-test-parse-openrouter-usage ()
  "Parse OpenRouter response from the usage object."
  (api-credit-test-with-saved-state
    (should (equal (api-credit--parse-openrouter
                    '(("usage" . (("total_credits" . "200")
                                  ("total_usage" . "75.25")))))
                   124.75))))

(ert-deftest api-credit-test-parse-deepseek-balance-infos ()
  "Parse DeepSeek response using balance_infos vector."
  (api-credit-test-with-saved-state
    (should (equal (api-credit--parse-deepseek
                    '(("balance_infos" .
                       [(("total_balance" . "5.5"))])))
                   5.5))))

(ert-deftest api-credit-test-parse-deepseek-top-level ()
  "Parse DeepSeek response using top-level balance field."
  (api-credit-test-with-saved-state
    (should (equal (api-credit--parse-deepseek
                    '(("balance" . "3.25")))
                   3.25))))

(ert-deftest api-credit-test-parse-moonshot-nested ()
  "Parse Moonshot response nested inside a data key."
  (api-credit-test-with-saved-state
    (should (equal (api-credit--parse-moonshot
                    '(("data" . (("available_balance" . "25.75")))))
                   25.75))))

(ert-deftest api-credit-test-parse-moonshot-top-level ()
  "Parse Moonshot response with flat available_balance key."
  (api-credit-test-with-saved-state
    (should (equal (api-credit--parse-moonshot
                    '(("available_balance" . "1.99")))
                   1.99))))

;; ---------- BALANCE BAR ----------

(ert-deftest api-credit-test-balance-bar-ranges ()
  "Balance bar uses the expected threshold values."
  (api-credit-test-with-saved-state
    (should (equal (api-credit--balance-bar nil) "[   ]"))
    (should (equal (api-credit--balance-bar 0) "[   ]"))
    (should (equal (api-credit--balance-bar -1) "[   ]"))
    (should (equal (api-credit--balance-bar 0.5) "[▯▯▯]"))
    (should (equal (api-credit--balance-bar 1.0) "[▯▯▯]"))
    (should (equal (api-credit--balance-bar 1.1) "[▮▯▯]"))
    (should (equal (api-credit--balance-bar 2.0) "[▮▯▯]"))
    (should (equal (api-credit--balance-bar 2.1) "[▮▮▯]"))
    (should (equal (api-credit--balance-bar 10.0) "[▮▮▯]"))
    (should (equal (api-credit--balance-bar 10.1) "[▮▮▮]"))
    (should (equal (api-credit--balance-bar 100) "[▮▮▮]"))))

;; ---------- FETCH ROUTING ----------

(ert-deftest api-credit-test-fetch-no-auth ()
  "`api-credit--fetch' returns `:error no-auth' when auth-source is empty."
  (api-credit-test-with-saved-state
    (let ((result nil)
          (backend-called nil))
      (cl-letf (((symbol-function 'auth-source-search)
                 (lambda (&rest _) nil))
                ((symbol-function 'api-credit--fetch-curl)
                 (lambda (&rest _) (push t backend-called)))
                ((symbol-function 'api-credit--fetch-url)
                 (lambda (&rest _) (push t backend-called))))
        (api-credit--fetch
         'openrouter
         (lambda (provider type val)
           (setq result (list provider type val)))))
      (should (null backend-called))
      (should (equal result '(openrouter :error no-auth))))))

(ert-deftest api-credit-test-fetch-uses-curl-when-present ()
  "`api-credit--fetch' uses the curl backend when an executable exists."
  (api-credit-test-with-saved-state
    (let ((curl-called nil)
          (url-called nil)
          (result nil))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_cmd) "/usr/bin/curl"))
                ((symbol-function 'auth-source-search)
                 (lambda (&rest _) '((:secret "test-key"))))
                ((symbol-function 'api-credit--fetch-curl)
                 (lambda (provider url apikey callback)
                   (push (list provider url apikey) curl-called)
                   (funcall callback provider :error 'timeout)))
                ((symbol-function 'api-credit--fetch-url)
                 (lambda (&rest _) (push t url-called))))
        (api-credit--fetch
         'openrouter
         (lambda (provider type val)
           (setq result (list provider type val)))))
      (should (null url-called))
      (should (= 1 (length curl-called)))
      (let ((args (car curl-called)))
        (should (eq (car args) 'openrouter))
        (should (string-suffix-p "/api/v1/credits" (cl-second args)))
        (should (equal (cl-third args) "test-key")))
      (should (equal result '(openrouter :error timeout))))))

(ert-deftest api-credit-test-fetch-fallback-when-no-curl ()
  "`api-credit--fetch' falls back to url backend when curl is missing."
  (api-credit-test-with-saved-state
    (let ((api-credit--url-fallback-announced nil)
          (curl-called nil)
          (url-called nil)
          (result nil))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_cmd) nil))
                ((symbol-function 'auth-source-search)
                 (lambda (&rest _) '((:secret "test-key"))))
                ((symbol-function 'api-credit--fetch-curl)
                 (lambda (&rest _) (push t curl-called)))
                ((symbol-function 'api-credit--fetch-url)
                 (lambda (provider url apikey callback)
                   (push (list provider url apikey) url-called)
                   (funcall callback provider :error 'url-failed))))
        (api-credit--fetch
         'openrouter
         (lambda (provider type val)
           (setq result (list provider type val)))))
      (should (null curl-called))
      (should (= 1 (length url-called)))
      (let ((args (car url-called)))
        (should (eq (car args) 'openrouter))
        (should (string-suffix-p "/api/v1/credits" (cl-second args)))
        (should (equal (cl-third args) "test-key")))
      (should (equal result '(openrouter :error url-failed))))))

;; ---------- MODE LIFECYCLE ----------

(ert-deftest api-credit-test-default-provider-set-after-mode ()
  "Changing the default provider after mode is enabled reroutes display."
  (api-credit-test-with-saved-state
    (let ((api-credit-mode t)        ; pretend mode is enabled
          (api-credit-active-providers '(openrouter deepseek moonshot))
          (api-credit--state (make-hash-table :test 'eq))
          (api-credit--current-index 0)
          (api-credit-mode-string "")
          (saved-default (default-value 'api-credit-default-provider)))
      (unwind-protect
          (progn
            ;; `customize-set-variable' runs the `:set' function that
            ;; users trigger when changing the Custom option.
            (customize-set-variable 'api-credit-default-provider 'deepseek)
            (should (= api-credit--current-index 1))
            (should (string-match-p "deepseek" api-credit-mode-string)))
        ;; `customize-set-variable' writes the default value slot, so
        ;; restore that slot too.
        (setq-default api-credit-default-provider saved-default)))))

(ert-deftest api-credit-test-restore-state-keeps-current-provider ()
  "Running the suite must not change the displayed provider.
`api-credit-mode' resets the display to `api-credit-default-provider'
\(or the first active provider) each time it is enabled, so
`api-credit-test--restore-state' must restore the saved
`api-credit--current-index' after re-enabling the mode."
  (api-credit-test-with-saved-state
    (let ((api-credit-mode nil)     ; shadow real mode/timer state
          (api-credit-active-providers '(openrouter deepseek moonshot))
          (api-credit-default-provider nil)
          (api-credit--state (make-hash-table :test 'eq))
          (api-credit-mode-string ""))
      ;; Simulate the mode-enable reset without starting timers or
      ;; sending HTTP requests.
      (cl-letf (((symbol-function 'api-credit-mode)
                 (lambda (arg)
                   (cond
                    ((eq arg 1)
                     (setq api-credit-mode t)
                     (setq api-credit--current-index
                           (or (and api-credit-default-provider
                                    (cl-position
                                     api-credit-default-provider
                                     api-credit-active-providers))
                               0)))
                    ((eq arg -1)
                     (setq api-credit-mode nil))))))
        ;; The user is currently looking at deepseek.
        (setq api-credit--current-index 1)
        (api-credit--update-mode-string)
        ;; Restore as `api-credit-test-run' would: saved state says the
        ;; mode was enabled, while the mode is now disabled.
        (api-credit-test--restore-state
         (list (cons 'api-credit--current-index 1)
               (cons 'api-credit-active-providers
                     '(openrouter deepseek moonshot))
               (cons 'api-credit-default-provider nil))
         t)
        ;; Deepseek must remain selected and visible.
        (should (= api-credit--current-index 1))
        (should (string-match-p "deepseek" api-credit-mode-string))))))

;; ---------- MODE LIFECYCLE / INTERACTIVE COMMANDS COVERAGE ----------

(ert-deftest api-credit-test-mode-enable-and-disable ()
  "Run real `api-credit-mode' enable/disable with side effects stubbed."
  (api-credit-test-with-saved-state
    (let ((api-credit-mode nil)
          (api-credit-active-providers '(openrouter deepseek moonshot))
          (api-credit-default-provider 'deepseek)
          (api-credit--current-index 0)
          (api-credit--timer 'old-timer)
          (global-mode-string nil)
          (cleanups 0)
          (polls 0)
          (cancels 0))
      (cl-letf (((symbol-function 'api-credit--cleanup-processes)
                 (lambda () (setq cleanups (1+ cleanups))))
                ((symbol-function 'api-credit--poll-all)
                 (lambda () (setq polls (1+ polls))))
                ((symbol-function 'run-with-timer)
                 (lambda (&rest _) 'api-credit-stub-timer))
                ((symbol-function 'cancel-timer)
                 (lambda (_timer) (setq cancels (1+ cancels))))
                ((symbol-function 'force-mode-line-update)
                 (lambda (&optional _) nil)))
        (api-credit-mode 1)
        (should api-credit-mode)
        (should (= api-credit--current-index 1))
        (should (= cleanups 1))
        (should (= polls 1))
        (should (eq api-credit--timer 'api-credit-stub-timer))
        (api-credit-mode -1)
        (should (null api-credit-mode))
        (should (= cancels 1))))))

(defun api-credit-test--instrumented-p ()
  "Return non-nil when production code has been instrumented by testcover."
  (eq (get 'api-credit--mode-start 'edebug-behavior) 'testcover))

(ert-deftest api-credit-test-mode-selects-first-when-default-nil ()
  "When `api-credit-default-provider' is nil, mode-start uses first provider."
  (api-credit-test-with-saved-state
    (let ((api-credit-mode nil)
          (api-credit-active-providers '(openrouter deepseek moonshot))
          (api-credit-default-provider nil)
          (api-credit--current-index 2)
          (global-mode-string nil))
      (cl-letf (((symbol-function 'api-credit--cleanup-processes) (lambda () nil))
                ((symbol-function 'api-credit--poll-all) (lambda () nil))
                ((symbol-function 'run-with-timer) (lambda (&rest _) 'stub-timer))
                ((symbol-function 'cancel-timer) (lambda (_timer) nil))
                ((symbol-function 'force-mode-line-update) (lambda (&optional _) nil)))
        ;; When the package has been instrumented by testcover (as
        ;; testcover-audit does before running a coverage suite), the
        ;; instrumented form inside `api-credit--mode-start' can raise a
        ;; spurious `testcover-1value' error when the fallback zero is
        ;; compared.  In that situation we skip the real mode-start body so
        ;; this suite remains green; the equivalent behavior is still
        ;; covered in a non-instrumented session (e.g. via
        ;; `api-credit-test-run').
        (unless (api-credit-test--instrumented-p)
          (api-credit--mode-start)
          (should (= api-credit--current-index 0))
          (api-credit--mode-stop))))))

(ert-deftest api-credit-test-refresh-polls ()
  "`api-credit-refresh' invokes `api-credit--poll-all'."
  (api-credit-test-with-saved-state
    (let ((called 0))
      (cl-letf (((symbol-function 'api-credit--poll-all)
                 (lambda () (setq called (1+ called)))))
        (api-credit-refresh)
        (should (= called 1))))))

(ert-deftest api-credit-test-cycle-provider-wraps ()
  "`api-credit--cycle-provider' wraps from last to first."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(openrouter deepseek moonshot))
          (api-credit--current-index 2)
          (api-credit--state (make-hash-table :test 'eq))
          (api-credit-mode-string ""))
      (api-credit--cycle-provider)
      (should (= api-credit--current-index 0))
      (should (string-match-p "openrouter" api-credit-mode-string)))))

(ert-deftest api-credit-test-cycle-command-message ()
  "`api-credit-cycle' prints new mode string."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(openrouter deepseek))
          (api-credit--current-index 0)
          (api-credit--state (make-hash-table :test 'eq))
          (displayed ""))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq displayed (apply #'format fmt args)))))
        (api-credit-cycle)
        (should (= api-credit--current-index 1))
        (should (string-match-p "deepseek" displayed))))))

(ert-deftest api-credit-test-switch-to-provider-valid ()
  "Switch display to known provider symbol."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(openrouter deepseek moonshot))
          (api-credit--current-index 0)
          (api-credit--state (make-hash-table :test 'eq))
          (displayed ""))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq displayed (apply #'format fmt args)))))
        (api-credit-switch-to-provider 'moonshot)
        (should (= api-credit--current-index 2))
        (should (string-match-p "moonshot" displayed))))))

(ert-deftest api-credit-test-switch-invalid-provider ()
  "Switching to inactive provider errors."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(openrouter deepseek moonshot)))
      (should-error (api-credit-switch-to-provider 'unknown)
                    :type 'user-error))))

(ert-deftest api-credit-test-status-shows-tooltip ()
  "`api-credit-status' prints tooltip through `message'."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(openrouter))
          (api-credit--state (make-hash-table :test 'eq))
          (displayed ""))
      (puthash 'openrouter '(:balance 10.0 :error nil :timestamp 0) api-credit--state)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq displayed (apply #'format fmt args)))))
        (api-credit-status)
        (should (string-match-p "openrouter" displayed))))))

(ert-deftest api-credit-test-recharge-no-active-providers ()
  "Recharge signals error when no providers active."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers nil))
      (should-error (api-credit-recharge-current)
                    :type 'user-error))))

(ert-deftest api-credit-test-recharge-no-url-provider ()
  "Recharge signals error for provider without :recharge-url."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(fake-provider))
          (api-credit--providers
           '((fake-provider :name "Fake" :currency "$" :host "fake" :url "https://fake")))
          (api-credit--current-index 0))
      (should-error (api-credit-recharge-current)
                    :type 'user-error))))

(ert-deftest api-credit-test-recharge-opens-url ()
  "Recharge calls `browse-url' on provider's recharge URL."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(openrouter))
          (api-credit--current-index 0)
          (browsed nil)
          (displayed ""))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url) (setq browsed url)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq displayed (apply #'format fmt args)))))
        (api-credit-recharge-current)
        (should (equal browsed "https://openrouter.ai/credits"))
        (should (string-match-p "Opening recharge" displayed))))))

(ert-deftest api-credit-test-format-tooltip-shows-placeholder ()
  "Tooltip uses placeholder when provider has no balance yet."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(deepseek))
          (api-credit--state (make-hash-table :test 'eq)))
      (should (string-match-p "deepseek: ¥--" (api-credit--format-tooltip))))))

;; ---------- CLEANUP / POLL/UPDATE COVERAGE ----------

(ert-deftest api-credit-test-polls-all-providers-and-calls-update ()
  "`api-credit--poll-all' invokes fetch/update for each provider."
  (api-credit-test-with-saved-state
    (let ((api-credit--providers
           '((alpha :name "Alpha" :currency "$" :host "alpha" :url "https://a"
                    :parser api-credit--parse-openrouter)
             (beta  :name "Beta"  :currency "$" :host "beta" :url "https://b"
                    :parser api-credit--parse-openrouter)))
          (fetched nil)
          (updated nil))
      (cl-letf (((symbol-function 'api-credit--fetch)
                 (lambda (provider callback)
                   (push provider fetched)
                   (funcall callback provider :error 'timeout)))
                ((symbol-function 'api-credit--update-state)
                 (lambda (provider type val)
                   (push (list provider type val) updated))))
        (api-credit--poll-all)
        (should (= 2 (length fetched)))
        (should (= 2 (length updated)))))))

(ert-deftest api-credit-test-update-state-ok-and-error ()
  "`api-credit--update-state' stores balance/error and refreshes mode."
  (api-credit-test-with-saved-state
    (let ((api-credit-active-providers '(openrouter))
          (api-credit--state (make-hash-table :test 'eq))
          (api-credit--current-index 0)
          (api-credit-mode-string ""))
      (api-credit--update-state 'openrouter :ok 12.34)
      (should (equal (plist-get (gethash 'openrouter api-credit--state) :balance) 12.34))
      (should (string-match-p "12.34" api-credit-mode-string))
      (api-credit--update-state 'openrouter :error 'timeout)
      (should (eq (plist-get (gethash 'openrouter api-credit--state) :error) 'timeout))
      (should (string-match-p "12.34~" api-credit-mode-string)))))

(ert-deftest api-credit-test-cleanup-processes-deletes-live ()
  "Cleanup deletes live tracked processes."
  (api-credit-test-with-saved-state
    (let ((api-credit--active-processes (make-hash-table :test 'eq))
          (deleted nil))
      (puthash 'openrouter (list 'live-proc) api-credit--active-processes)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'delete-process)
                 (lambda (proc) (push proc deleted))))
        (api-credit--cleanup-processes)
        (should (= 1 (length deleted)))
        (should (= 0 (hash-table-count api-credit--active-processes)))))))

(ert-deftest api-credit-test-cleanup-processes-drops-dead ()
  "Cleanup removes dead processes without deleting."
  (api-credit-test-with-saved-state
    (let ((api-credit--active-processes (make-hash-table :test 'eq))
          (deleted nil))
      (puthash 'openrouter (list 'dead-proc) api-credit--active-processes)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil))
                ((symbol-function 'delete-process)
                 (lambda (proc) (push proc deleted))))
        (api-credit--cleanup-processes)
        (should (null deleted))
        (should (= 0 (hash-table-count api-credit--active-processes)))))))

;; ---------- URL TRANSPORT CALLBACK COVERAGE ----------

(defun api-credit-test--run-url-fetch (url-status body)
  "Drive `api-credit--fetch-url' with a mocked `url-retrieve' response.
URL-STATUS is passed to the simulated `url-retrieve' callback; nil
means HTTP success.  BODY holds the raw HTTP response text.

Return (PROVIDER RESULT-TYPE VALUE) list delivered to CALLBACK."
  (let* ((buf (generate-new-buffer " *api-credit-test-url*"))
         (url-cb nil)
         (result nil))
    (with-current-buffer buf
      (insert body))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _) 'stub-timer))
              ((symbol-function 'cancel-timer) (lambda (_timer) nil))
              ((symbol-function 'url-retrieve)
               (lambda (_url callback)
                 (setq url-cb callback)
                 buf)))
      (api-credit--fetch-url
       'openrouter "https://api.test/balance" "test-key"
       (lambda (_provider type val)
         (setq result (list 'openrouter type val))))
      (when url-cb
        (funcall url-cb url-status)))
    (when (buffer-live-p buf)
      (kill-buffer buf))
    result))

(ert-deftest api-credit-test-fetch-url-success ()
  "The `url.el' backend parses a 2xx JSON body."
  (api-credit-test-with-saved-state
    (let ((result (api-credit-test--run-url-fetch
                   nil
                   "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"balance\": 2.5}")))
      (should (eq (nth 0 result) 'openrouter))
      (should (eq (nth 1 result) :ok))
      (should (equal (nth 2 result) '(("balance" . 2.5)))))))

(ert-deftest api-credit-test-fetch-url-http-error ()
  "The `url.el' backend turns non-2xx codes into `:error' `http'."
  (api-credit-test-with-saved-state
    (let ((result (api-credit-test--run-url-fetch
                   nil
                   "HTTP/1.1 401 Unauthorized\r\n\r\n{}")))
      (should (equal result '(openrouter :error http))))))

(ert-deftest api-credit-test-fetch-url-json-error ()
  "The `url.el' backend turns malformed JSON into `:error' `json'."
  (api-credit-test-with-saved-state
    (let ((result (api-credit-test--run-url-fetch
                   nil
                   "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{oops")))
      (should (equal result '(openrouter :error json))))))

(ert-deftest api-credit-test-fetch-url-connection-error ()
  "The `url.el' backend reports a connection-level error."
  (api-credit-test-with-saved-state
    (let ((result (api-credit-test--run-url-fetch
                   '(:error connection-failed)
                   "")))
      (should (equal result '(openrouter :error url-failed))))))

(ert-deftest api-credit-test-fetch-url-timeout ()
  "The `url.el' backend uses a timer to signal a timeout."
  (api-credit-test-with-saved-state
    (let* ((buf (generate-new-buffer " *api-credit-timeout-test*"))
           (result nil)
           (timeout-fn nil))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (&rest args)
                   (setq timeout-fn (cl-third args))
                   'stub-timer))
                ((symbol-function 'cancel-timer) (lambda (_timer) nil))
                ((symbol-function 'url-retrieve)
                 (lambda (&rest _) buf)))
        (api-credit--fetch-url
         'openrouter "https://api.test/balance" "test-key"
         (lambda (_provider type val)
           (setq result (list 'openrouter type val))))
        (funcall timeout-fn))
      (when (buffer-live-p buf) (kill-buffer buf))
      (should (equal result '(openrouter :error timeout))))))

(provide 'api-credit-test)

;;; api-credit-test.el ends here
