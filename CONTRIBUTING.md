# Contributing

Thanks for looking. The project is small on purpose: one web page, one PowerShell program, and a build script that welds them into `VoiceBeam.bat`.

## Build and test

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1        # rebuilds VoiceBeam.bat
powershell -ExecutionPolicy Bypass -File tests/run.ps1    # checks the file and the real server
```

`pwsh` (PowerShell 7) works too, on Windows, macOS and Linux. Nothing else is needed. GitHub Actions runs both scripts on Windows PowerShell 5.1, PowerShell 7 and Linux for every push and pull request.

## Layout

```
web/            the page the phone opens: index.html, style.css, app.js, locales/<code>.json
src/server.ps1  the PC side: QR code, HTTP server, request checks, clipboard + Ctrl+V
build.ps1       web/ + src/server.ps1  ->  VoiceBeam.bat (committed, so people can download it)
tests/run.ps1   the tests
docs/img/       screenshots
```

## Things to know before changing something

- **`VoiceBeam.bat` is generated.** Change `web/*` or `src/server.ps1`, run `build.ps1`, and commit the result; the tests fail when it is stale.
- **`src/server.ps1` stays pure ASCII.** cmd.exe reads the `.bat` in the console's code page; the page travels as base64 for the same reason. `$MaxLen` in it must match `$MaxLength` in `build.ps1`.
- **The text box does not get smaller.** 18px type, at least 220px tall, filling the screen. Make it bigger if you like.
- **The page never talks to the internet.** No CDN, no web fonts, no analytics; everything is inlined into one file.
- **Add a language:** copy `web/locales/en.json` to `web/locales/<code>.json` and translate the values. The language picker finds it by itself.
- **Add a style:** a style is a block of CSS variables in `web/style.css` (see `html[data-theme="business"]`), in a light and a dark version. Add its name to the two style pickers in `web/index.html`, to the list of known styles in `web/app.js` and in the small script at the top of `index.html`, and give it `theme.<name>` / `theme.<name>.desc` strings.
- **Security checks** (Host, Origin, Content-Type) are described in [SECURITY.md](SECURITY.md); keep them, and add a test for anything new.

## Pictures

Screenshots in `docs/img` show canned text only. Do not commit screenshots with real addresses, host names or conversations in them.
