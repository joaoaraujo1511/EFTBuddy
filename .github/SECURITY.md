# Security policy

## Reporting a vulnerability

Please report security issues **privately**, through GitHub's private
vulnerability reporting: open the repository's **Security** tab and choose
**Report a vulnerability**. Do not open a public issue, and please do not use
the in-site bug report form for this either: reports there are stored in the
app's database, not sent to a private channel.

Include what you found, how to reproduce it, and what an attacker could do with
it. A proof of concept against your own local copy is welcome; please do not
test against the live site in a way that affects other visitors or its data
sources.

## What to expect

EFT Buddy is a non-commercial project maintained in spare time, so there is no
formal SLA. You should get an acknowledgement within a week. Fixes land on
`main` and are deployed from there; there are no older release lines to patch.

If you would like credit, say how you want to be named, and it will go in the
advisory once the fix is out.

## Scope

In scope: this repository's code and its deployment configuration, for example
anything that lets a visitor read or change another visitor's progress, bypass
the Content-Security-Policy, reach the admin endpoint from outside the host,
crash the app with a crafted request, or exhaust its memory.

Out of scope: the upstream data sources (tarkov.dev, the Escape from Tarkov
Wiki) and Cloudflare, which have their own reporting channels, and findings
that need physical or administrative access to the host.
