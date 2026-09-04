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
  ;; First clean up any mode state left behind by tests.
  (when (and (fboundp 'api-credit-mode)
             (bound-and-true-p api-credit-mode))
    (api-credit-mode -1))
  ;; Restore the user's original global variable values.
  (dolist (cell saved)
    (set (car cell) (cdr cell)))
  ;; Re-enable mode only if it was enabled when the runner was invoked.
  (when (and mode-enabled-p (fboundp 'api-credit-mode))
    (api-credit-mode 1)))

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
  (let ((input "{\"balance\": 1.5}"))
    (should (equal (api-credit--json-parse input)
                   '(("balance" . 1.5))))))

;; ---------- PARSERS ----------

(ert-deftest api-credit-test-parse-openrouter-balance-field ()
  "Parse OpenRouter response with top-level balance field."
  (should (equal (api-credit--parse-openrouter
                  '(("balance" . "10.50")))
                 10.5)))

(ert-deftest api-credit-test-parse-openrouter-credits ()
  "Parse OpenRouter response from the nested credits format."
  (should (equal (api-credit--parse-openrouter
                  '(("data" . (("total_credits" . "100")
                               ("total_usage" . "40.5")))))
                 59.5)))

(ert-deftest api-credit-test-parse-openrouter-usage ()
  "Parse OpenRouter response from the usage object."
  (should (equal (api-credit--parse-openrouter
                  '(("usage" . (("total_credits" . "200")
                                ("total_usage" . "75.25")))))
                 124.75)))

(ert-deftest api-credit-test-parse-deepseek-balance-infos ()
  "Parse DeepSeek response using balance_infos vector."
  (should (equal (api-credit--parse-deepseek
                  '(("balance_infos" .
                     [(("total_balance" . "5.5"))])))
                 5.5)))

(ert-deftest api-credit-test-parse-deepseek-top-level ()
  "Parse DeepSeek response using top-level balance field."
  (should (equal (api-credit--parse-deepseek
                  '(("balance" . "3.25")))
                 3.25)))

(ert-deftest api-credit-test-parse-moonshot-nested ()
  "Parse Moonshot response nested inside a data key."
  (should (equal (api-credit--parse-moonshot
                  '(("data" . (("available_balance" . "25.75")))))
                 25.75)))

(ert-deftest api-credit-test-parse-moonshot-top-level ()
  "Parse Moonshot response with flat available_balance key."
  (should (equal (api-credit--parse-moonshot
                  '(("available_balance" . "1.99")))
                 1.99)))

;; ---------- BALANCE BAR ----------

(ert-deftest api-credit-test-balance-bar-ranges ()
  "Balance bar uses the expected threshold values."
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
  (should (equal (api-credit--balance-bar 100) "[▮▮▮]")))

;; ---------- FETCH ROUTING ----------

(ert-deftest api-credit-test-fetch-no-auth ()
  "`api-credit--fetch' returns `:error no-auth' when auth-source is empty."
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
    (should (equal result '(openrouter :error no-auth)))))

(ert-deftest api-credit-test-fetch-uses-curl-when-present ()
  "`api-credit--fetch' uses the curl backend when an executable exists."
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
    (should (equal result '(openrouter :error timeout)))))

(ert-deftest api-credit-test-fetch-fallback-when-no-curl ()
  "`api-credit--fetch' falls back to url backend when curl is missing."
  (let ((curl-called nil)
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
      (setq api-credit--url-fallback-announced nil)
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
    (should (equal result '(openrouter :error url-failed)))))

;; ---------- MODE LIFECYCLE ----------

(ert-deftest api-credit-test-default-provider-set-after-mode ()
  "Changing the default provider after mode is enabled reroutes display."
  (unwind-protect
      (progn
        (setq api-credit-active-providers '(openrouter deepseek moonshot)
              api-credit--state (make-hash-table :test 'eq)
              api-credit--current-index 0
              api-credit-mode-string "")
        (cl-letf (((symbol-function 'api-credit--poll-all) #'ignore)
                  ((symbol-function 'run-with-timer) (lambda (&rest _) nil)))
          (api-credit-mode 1)
          (customize-set-variable 'api-credit-default-provider 'deepseek)
          (should (= api-credit--current-index 1))
          (should (string-match-p "deepseek" api-credit-mode-string))))
    (when (bound-and-true-p api-credit-mode)
      (api-credit-mode -1))
    (setq api-credit-default-provider nil)))

(provide 'api-credit-test)

;;; api-credit-test.el ends here
