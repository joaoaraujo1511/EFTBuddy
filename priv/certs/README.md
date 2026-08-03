# Trust anchors

## `supabase-prod-ca-2021.crt`

Supabase's root certificate authority, `Supabase Root 2021 CA`. `config/runtime.exs`
reads it via `DB_CACERTFILE` and uses it — **instead of** the operating system's
trust store — to verify the database's TLS certificate.

### Why this file has to exist

Supabase runs its own PKI. The pooler serves this chain:

```
*.pooler.supabase.com
  └─ issued by  Supabase Intermediate 2021 CA
       └─ issued by  Supabase Root 2021 CA   ← self-signed, in NO OS trust store
```

That root is not in `ca-certificates`, Mozilla's bundle, or anything else
`:public_key.cacerts_get/0` returns. So `verify: :verify_peer` anchored to the OS
store **cannot** build a path to it and the handshake dies with
`Fatal - Unknown CA`. Anchoring to this file is what makes verification possible
at all; the alternative that was in use before was `DB_SSL_INSECURE=true`, which
verifies nothing and leaves the connection open to an active man in the middle.

Pinning here is *tighter* than the default, not a concession: this connection
trusts exactly one issuer instead of every public CA installed on the machine.

### Committing it is not a secret leak

This is a **public** certificate — the same file Supabase hands every customer,
containing a public key and no private key material. It is committed precisely so
that a deployment is a `git pull` rather than a `git pull` plus an out-of-band
file copy that someone will forget. Contrast `private/`, which is gitignored and
`.dockerignore`d because it holds real credentials.

### Re-verifying it

Do not trust this file because it is in the repository. It was checked against
the certificate the production pooler actually serves, and you can repeat that:

```sh
# What this file claims to be
openssl x509 -in priv/certs/supabase-prod-ca-2021.crt -noout -subject -fingerprint -sha256

# What the live database actually presents as its root.
# DB_HOST is your pooler hostname, e.g. aws-N-<region>.pooler.supabase.com —
# take it from DATABASE_URL rather than hardcoding it here.
DB_HOST=...
openssl s_client -starttls postgres -showcerts \
  -connect "$DB_HOST:5432" -servername "$DB_HOST" </dev/null 2>/dev/null \
  | awk '/BEGIN CERT/{n++} n==3' \
  | openssl x509 -noout -subject -fingerprint -sha256
```

Both must print:

```
subject=C=US, ST=Delware, L=New Castle, O=Supabase Inc, CN=Supabase Root 2021 CA
sha256 Fingerprint=80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA
```

Note the second command reads the root *from the connection being verified*, which
on its own is circular. The authoritative copy is the download under
**Database → Settings → SSL Configuration** in the Supabase dashboard, fetched
over a publicly-trusted HTTPS connection. (Supabase's old direct link,
`supabase.com/downloads/prod-ca-2021.crt`, now returns 404 — the dashboard is the
only current source.) This file came from that dashboard download and matched the
live chain.

### Expiry

`notAfter = Apr 26 10:56:53 2031 GMT`. When Supabase rotates its root, the app
stops connecting and says so at boot; replace this file and redeploy.
