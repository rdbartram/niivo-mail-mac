# Third-party notices

niivo mail for macOS is licensed under Apache 2.0 (see `LICENSE` and `NOTICE`). It uses or can be built with the
components below, each under its own licence. This file lists what the repository depends on as of this commit
(`Package.swift`, `Package.resolved`, `Sources/CompliantCalendar/Resources/`, `scripts/bundle.sh`).

---

## Included in builds

### Microsoft Authentication Library (MSAL) for iOS and macOS

- **What:** sign-in and token cache. The only SwiftPM dependency.
- **Source:** <https://github.com/AzureAD/microsoft-authentication-library-for-objc>, resolved through SwiftPM
  (`Package.resolved` pins 2.18.1).
- **How it ships:** `scripts/bundle.sh` copies `MSAL.framework` into `Contents/Frameworks` and re-signs it.
- **Licence:** MIT License, Copyright (c) Microsoft Corporation. The full text is in the package's `LICENSE` file
  (`.build/checkouts/microsoft-authentication-library-for-objc/LICENSE` after `swift build`).

### Fonts

Both fonts live in `Sources/CompliantCalendar/Resources/Fonts/`, and the SwiftPM resource bundle copies them into the
app.

| File | Font | Copyright |
|---|---|---|
| `instrument-sans-latin.woff2` | Instrument Sans | Copyright 2022 The Instrument Sans Project Authors (<https://github.com/Instrument/instrument-sans>) |
| `jetbrains-mono-latin.woff2` | JetBrains Mono | Copyright 2020 The JetBrains Mono Project Authors (<https://github.com/JetBrains/JetBrainsMono>) |

- **Licence:** SIL Open Font License, Version 1.1. The full text is in
  `Sources/CompliantCalendar/Resources/Fonts/OFL.txt`. Under the OFL the fonts may be bundled with software but not
  sold on their own. Modified versions may not use a Reserved Font Name.

### Apple system frameworks and libraries

These are part of macOS and aren't redistributed: SwiftUI, AppKit, WebKit, CryptoKit, Security, LocalAuthentication,
Foundation Models (where available), and the system `libsqlite3`.

---

## Not included: the Microsoft Information Protection (MIP) SDK

Decrypting Purview-protected mail uses Microsoft's **MIP File, Protection and Policy SDKs (C++)**. **None of it is in
this repository.** `vendor/` is git-ignored.

- **Getting it:** download it from Microsoft yourself. The version, URLs and SHA-256 hashes are in `docs/MIP.md`. You
  accept Microsoft's licence terms when you download it, and you're responsible for complying with them.
- **Licence:** per `docs/MIP.md`, the SDK headers and samples are MIT-licensed. The **binaries** are under the
  "Microsoft Software License Terms — Microsoft Information Protection SDK" (`LicenseTerms.rtf` in the download).
  - They allow development and testing.
  - They allow redistribution only of the files listed in the SDK's `redist.txt`, and only under conditions. These
    include adding significant functionality, end-user terms at least as protective, and calling the SDK's audit API.
  - Microsoft also requires a signed **Information Protection Integration Agreement (IPIA)** before an MIP-enabled
    app is released publicly.
- **What ends up in the app:** only when you build it in. That means `vendor/mip/` is present, a real
  `SIGN_IDENTITY` is set, and `BUNDLE_MIP` isn't `0`. In that case `scripts/bundle.sh` copies:
  - our bridge, `libniivo_mipbridge.dylib`, which we build from `native/mipbridge/` (Apache 2.0, this project)
  - **every runtime dylib in the SDK's `bins/release/arm64/`**, except the `*_nostrip` variants, into
    `Contents/Frameworks`, re-signed with your identity
- **Not yet compliant:** that set is wider than the four libraries in `redist.txt` (`libmip_core`, `libmip_file_sdk`,
  `libmip_protection_sdk`, `libmip_upe_sdk`). The SDK's own dependencies (OpenSSL, GLib/GIO, GMime, libgsf,
  GPGME/libassuan/libgpg-error, libintl, libidn2, libunistring, PCRE2) carry their own licences, listed in the SDK's
  `ThirdPartyNotice.txt`. **Don't distribute a MIP-enabled build until that gap, the audit-API requirement and the
  IPIA are resolved** (`docs/MIP.md`, "Licence / redistribution").
- **Default builds:** a build without the SDK contains none of these files. `ProtectedContent` loads the bridge with
  `dlopen` at runtime, and no SwiftPM product links the SDK.

---

## Optional external tools (not bundled)

The app can call these if you install and configure them. They aren't distributed with niivo mail, and their own
terms apply:

- the `claude` command-line tool, an optional AI provider
- any OpenAI-compatible endpoint you configure, such as OpenAI, Azure OpenAI, Ollama or LM Studio
- Azure CLI (`az`), used by `infra/entra/register.sh`
- Python 3, used by `scripts/devtoken.py`
