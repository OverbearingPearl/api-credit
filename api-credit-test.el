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

(provide 'api-credit-test)

;;; api-credit-test.el ends here
