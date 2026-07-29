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

Add entries to `~/.authinfo` or `~/.authinfo.gpg`:

```
machine openrouter.ai password sk-or-v1-...
machine deepseek.com password sk-...
machine moonshot.cn password sk-...
```

`pearl-credit` reads your authinfo and polls supported providers automatically.

## Supported Providers

| Provider | Status | Balance Endpoint |
|----------|--------|------------------|
| OpenRouter | yes | `https://openrouter.ai/api/v1/key` |
| DeepSeek | yes | `https://api.deepseek.com/user/balance` |
| Moonshot | yes | `https://api.moonshot.cn/v1/users/me/balance` |
| Anthropic | no | No public balance API |
| OpenAI | no | No public balance API |

## Commands

- `M-x pearl-credit-refresh` - force refresh all balances

## Variables

```elisp
(setq pearl-credit-poll-interval 300)  ; seconds
(setq pearl-credit-timeout 10)         ; seconds
```

A tilde (`~`) after a value means the last poll failed.

## License

GPL-3.0-or-later
