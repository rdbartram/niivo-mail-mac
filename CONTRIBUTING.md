# Contributing

Thanks for looking. The project is young, so please open an issue to talk through anything bigger than a bug fix
before you write it.

## Ground rules

- **Never commit tenant data.** That covers real mail, calendar items, screenshots of real mailboxes, tenant IDs,
  client IDs, tokens and names. Tests and screenshots use the synthetic fixtures. `build.env`, `config.json`, `vendor/`
  and `signing/` stay out of git.
- **Fail closed.** If a change touches labels, rights, the cache, AI or MCP, the safe outcome on any error or unknown
  is *less* access. Make it go through the existing gates (`AIGatePolicy`, `ContentPolicy`, the `MailStore` persist
  rule, `TrustPolicy.apply`). Don't add a parallel path.
- **Don't overclaim.** If something can't be checked without a tenant, write **UNVERIFIED** next to it in the docs or
  code comments, and say what would verify it.
- **No new network destinations or telemetry** without an issue that discusses it first.

## Before you open a pull request

```bash
swift build
swift run CoreSelfTest           # must end with ALL CHECKS PASSED
```

Add `CoreSelfTest` checks for new core logic. `swift test` doesn't work under the Command Line Tools, so the runner
stands in for it. If you change UI, say whether you clicked it through by hand.

## Security issues

Please don't use issues or pull requests. See [SECURITY.md](SECURITY.md).

## Licence

Contributions are accepted under the Apache License 2.0 (section 5 of `LICENSE`). By opening a pull request you confirm
that you have the right to submit the work under that licence.
