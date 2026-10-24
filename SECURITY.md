# Security

## The short version

VoiceBeam has **no login**. While it runs, anyone who can reach the PC's port (8123 by default) can type text on that PC — and, with the Enter switch on, press Enter. That is the whole point of the tool and it is fine on a home or office network you trust. It is wrong for a café, hotel or conference network.

- Allow it through the Windows firewall for **private** networks only.
- Close it when you are not dictating.
- Do not forward its port to the internet.

## What the server checks

Every `POST /api/send` has to pass these checks, in this order. They exist so that *another web page* cannot use your browser as a stepping stone to type on your PC.

| Check | Refused with | What it stops |
| --- | --- | --- |
| `Host` must be an IP address, `localhost`, a `.local` name or this machine's own name (add more with `--allow-host`) | `403 bad_host` | **DNS rebinding**: a web page on `evil.example` whose DNS answer is switched to your PC's address would otherwise count as "same origin" |
| `Origin`, when the browser sends one, must be this very site | `403 bad_origin` | Another site posting to your PC's address from the visitor's browser |
| `Content-Type` must be `application/json` | `415 bad_content_type` | A plain `<form>` or a `no-cors` `fetch` can only send "simple" content types; anything else needs a CORS pre-flight, which this server never approves |
| Body at most `16384 × 12 + 256` bytes, text at most 16384 characters | `413` / `400` | Memory use and runaway pastes |

`tests/run.ps1` starts the real server inside `VoiceBeam.bat` and checks every one of these; GitHub Actions runs it on Windows PowerShell 5.1, PowerShell 7 and Linux.

## What it does not protect against

- **Other devices on your network.** There is no pairing step. A PIN or a per-session token in the QR code would close this; it is not implemented because it changes how a phone bookmarks the page, and the tool is meant for networks you trust.
- **Anyone who can read your network traffic.** The page and the text travel as plain HTTP on your LAN, not HTTPS.
- **Software already running on the PC.** It can do far worse than call this API.

## What is stored, logged and sent

- The text is kept in memory only long enough to paste it. It is not written to disk and not logged anywhere.
- Your *text* clipboard is replaced for a moment (about 0.2 seconds) and put back. Anything that is not text (an image, files) cannot be restored.
- The page makes no requests outside your computer: no fonts, scripts, images or analytics from the internet (the page is a single file with everything inlined). The phone keeps only your preferences — style, light/dark, text size, language, the Enter switch — in the browser's local storage.

## Reporting a problem

If it is something that should not be public yet, please use **Report a vulnerability** on the repository's Security tab (GitHub's private vulnerability reporting). Anything else: open an issue.
