# pearl-credit

AI API balance in the Emacs modeline. No browser, no blocking, no fuss.

## Install

```elisp
(use-package pearl-credit
  :ensure t
  :config
  (pearl-credit-mode 1))
```

## Setup

API keys are read from `~/.authinfo` or `~/.authinfo.gpg`:

```
machine api.openrouter.ai password sk-or-v1-...
machine api.deepseek.com password sk-...
```

That's it. `pearl-credit` auto-detects providers from your authinfo entries.

If you prefer explicit configuration:

```elisp
(setq pearl-credit-providers
      '((openrouter :label "OR")
        (deepseek   :label "DS")))
```

Or disable auto-detection entirely:

```elisp
(setq pearl-credit-auto-detect nil)
```

## Supported Providers

| Provider | Status | Authinfo machine |
|----------|--------|------------------|
| OpenRouter | ✅ | `api.openrouter.ai` |
| DeepSeek | ✅ | `api.deepseek.com` |
| Moonshot / Kimi | ✅ | `api.moonshot.cn` |
| Anthropic | ❌ | No public balance API |
| OpenAI | ❌ | No public balance API |

## Commands

| Command | Binding | Description |
|---------|---------|-------------|
| `pearl-credit-refresh` | — | Force refresh all balances |
| `pearl-credit-show-details` | — | Full breakdown buffer |

## Customization

```
M-x customize-group RET pearl-credit RET
```

| Variable | Default | Description |
|----------|---------|-------------|
| `pearl-credit-poll-interval` | `300` | Seconds between polls |
| `pearl-credit-format` | `"[%s]"` | Modeline format |
| `pearl-credit-timeout` | `10` | Request timeout (seconds) |

A tilde (`~`) after a value means the last poll failed — the number is stale.

## License

GPL-3.0-or-later
