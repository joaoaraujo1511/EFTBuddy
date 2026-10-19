## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## How it was tested

<!-- New tests, and anything checked by hand (which pages, which data). -->

- [ ] `mix precommit` passes
- [ ] `mix credo` passes
- [ ] `node --test "assets/js/*.test.mjs"` passes (if `assets/js` changed)
- [ ] A new test fails without this change

## Checklist

- [ ] Comments next to changed code still describe what it does
- [ ] New environment variables are in `.env.example`
- [ ] New migrations roll back cleanly
- [ ] Nothing here can shrink or wipe a visitor's saved progress
