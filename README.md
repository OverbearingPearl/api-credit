# pearl-credit

AI API balance in the Emacs modeline. No browser, no blocking, no fuss.

## Install

```elisp
(use-package pearl-credit
  :ensure t
  :bind (("C-c A r" . pearl-credit-refresh)
         ("C-c A c" . pearl-credit-cycle)
         ("C-c A s" . pearl-credit-switch-to-provider)
         ("C-c A S" . pearl-credit-status))
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
| OpenRouter | yes | `https://openrouter.ai/api/v1/credits` |
| DeepSeek | yes | `https://api.deepseek.com/user/balance` |
| Moonshot | yes | `https://api.moonshot.cn/v1/users/me/balance` |
| Anthropic | no | No public balance API |
| OpenAI | no | No public balance API |

## Commands

- `M-x pearl-credit-refresh` — Force refresh all balances
- `M-x pearl-credit-cycle` — Switch to next provider in rotation
- `M-x pearl-credit-switch-to-provider` — Jump directly to a specific provider (with completion)
- `M-x pearl-credit-recharge-current` — Open browser to current provider's recharge page
- `M-x pearl-credit-status` — Show all provider balances in tooltip format
- `M-x pearl-credit-mode` — Toggle display on/off

## Display Format

Balances appear as `[█]openrouter:$5.00` with Unicode block bars indicating relative amount (0-10 scale):

- `[█]` `[▇]` `[▆]` `[▅]` `[▄]` `[▃]` `[▂]` `[▁]` — Full to empty
- **Green** (≥ 2.0): Healthy balance
- **Orange** (1.0–2.0): Low balance warning
- **Red** (< 1.0): Critical low balance
- `~` suffix: Stale data (last fetch failed)

## Variables

### Thresholds

```elisp
(setq pearl-credit-low-threshold 1.0)      ; Red when below
(setq pearl-credit-warning-threshold 2.0)  ; Orange when below
```

### Faces

```elisp
(custom-set-faces
 '(pearl-credit-critical ((t (:foreground "red" :weight bold))))
 '(pearl-credit-warning ((t (:foreground "orange"))))
 '(pearl-credit-normal ((t (:foreground "green")))))
```

### Timing

- `pearl-credit-poll-interval` — Seconds between automatic updates (default: 300)
- `pearl-credit-timeout` — HTTP request timeout (default: 10)

## License

GPL-3.0-or-later
