# Contributing to EFT Buddy

Thanks for helping. Bug reports, fixes and improvements are all welcome.

## Before you start

- **Bugs:** open an issue with the bug template. For a security issue, follow
  [`SECURITY.md`](SECURITY.md) instead.
- **Larger changes:** open an issue first, so we can agree on the approach before
  you spend time on it.
- **Game data that is wrong** (a quest, an item, a price) usually comes from
  upstream. The catalogue is rebuilt from the tarkov.dev API and the Escape from
  Tarkov Wiki, never edited by hand, so the fix may belong there.

## Setting up

The [README](../README.md) covers running the app and the tests. In short: the
Erlang and Elixir versions in `.tool-versions`, a local PostgreSQL, then
`mix setup` and `mix phx.server`.

## Making a change

- **Read `AGENTS.md`.** It holds the Elixir, Phoenix, LiveView and Ecto
  conventions this codebase follows, and they are binding.
- **Read the comments around what you change.** They explain *why*, and often
  record that the obvious alternative was tried and broke something. If your
  change makes a comment wrong, update the comment.
- **Add a test that fails without your change.** Tests that talk to tarkov.dev
  or the wiki use `Req.Test` stubs against captured payloads in
  `test/fixtures/`, never the network.
- **Configuration** is read at runtime in `config/runtime.exs`. A new variable
  goes in `.env.example` too; a test checks.
- **Migrations** must be reversible: CI rolls the whole schema down and back up.

## Before you open a pull request

```sh
mix precommit                          # audits, compile, format, Sobelow, tests
mix credo                              # blocking in CI
node --test "assets/js/*.test.mjs"     # browser-side progress helpers
```

`mix precommit` formats your code; commit the result.

## Pull requests

- Keep each one to a single change, and say why in the description, not only
  what.
- CI ("Build & test" and the production image build) must pass before a PR can
  merge into `main`.
- Pull requests are squash-merged, so the PR title becomes the commit message.
  Write it as a sentence in the imperative ("Fix the flea filter resetting on
  sort"), not as a type prefix.

## Licence

By contributing, you agree that your contribution is licensed under the
[GNU AGPL v3](../LICENSE), like the rest of the project. Content from the
Escape from Tarkov Wiki keeps its own licence (CC BY-NC-SA); see
[`NOTICE`](../NOTICE).
