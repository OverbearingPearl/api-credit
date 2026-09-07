# api-credit

AI API balance in the Emacs modeline. No browser, no blocking, no fuss.

![openrouter](screenshots/screenshot-openrouter.png)

## Requirements

- Emacs 25.1+
- curl is optional: used automatically when found on `exec-path`,
  otherwise the built-in `url.el` transport is used (announced once
  in `*Messages*`). No configuration needed.

## Install

```elisp
(use-package api-credit
  ;; Optional: start with specific provider instead of first active
  ;; :custom
  ;; (api-credit-default-provider 'deepseek)
  :ensure t
  :bind (("C-c A r" . api-credit-refresh)
         ("C-c A c" . api-credit-cycle)
         ("C-c A s" . api-credit-switch-to-provider)
         ("C-c A S" . api-credit-status))
  :config
  (api-credit-mode 1))
```

## Setup

Add entries to `~/.authinfo` or `~/.authinfo.gpg`:

```
machine openrouter.ai password sk-or-v1-...
machine deepseek.com password sk-...
machine moonshot.cn password sk-...
```

`api-credit` reads your authinfo and polls supported providers automatically.

## Supported Providers

| Provider | Balance Endpoint |
|----------|------------------|
| OpenRouter | `https://openrouter.ai/api/v1/credits` |
| DeepSeek | `https://api.deepseek.com/user/balance` |
| Moonshot | `https://api.moonshot.cn/v1/users/me/balance` |

## Not Supported

These providers do not offer a public balance API that can be
queried with a plain API key, so `api-credit` cannot show them:

- **OpenAI** — no official balance endpoint; the legacy
  `/v1/dashboard/billing/*` routes were unofficial and are no longer
  reliable
- **Anthropic** — the Admin API reports usage only and requires a
  separate admin key
- **Google (Gemini)** — billing is only available through the
  OAuth-protected Google Cloud Billing API

Mistral, Cohere, Groq, Perplexity and xAI also publish no public
balance API.

## Commands

- `M-x api-credit-refresh` — Force refresh all balances
- `M-x api-credit-cycle` — Switch to next provider in rotation
- `M-x api-credit-switch-to-provider` — Jump directly to a specific provider (with completion)
- `M-x api-credit-recharge-current` — Open browser to current provider's recharge page
- `M-x api-credit-status` — Show all provider balances in tooltip format
- `M-x api-credit-mode` — Toggle display on/off

## Display Format

Balances appear as `[▮▯▯]$2.00(openrouter)` with 3‑character Unicode bars:

- `[   ]` — Balance ≤ 0
- `[▯▯▯]` — Balance ≤ 1.0
- `[▮▯▯]` — Balance ≤ 2.0
- `[▮▮▯]` — Balance ≤ 10.0
- `[▮▮▮]` — Balance > 10.0

`~` suffix: Stale data (last fetch failed)

## Variables

### Display

- `api-credit-default-provider` — Default provider to display on startup
  - `nil` (default): Start with the first active provider
  - Symbol like `openrouter`, `deepseek`, or `moonshot`: Jump to that provider if active

Example: `(setq api-credit-default-provider 'deepseek)`

### Timing

- `api-credit-poll-interval` — Seconds between automatic updates (default: 300)
- `api-credit-timeout` — HTTP request timeout in seconds (default: 10); applies to both transports (curl `--max-time`, or a timer for `url.el`)

## License

GPL-3.0-or-later
