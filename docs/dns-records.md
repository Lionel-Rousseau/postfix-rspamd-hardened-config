# DNS Records

This document covers the DNS configuration that underpins the mail
authentication and security chain. Most of it is invisible in the
configuration files but is inseparable from the platform's posture.

---

## Record inventory

| Record | Value / Format | Purpose |
|---|---|---|
| `MX 10` | `web-mail.example.org` | Primary MX |
| `MX 20` | `mx-secondary.example.org` | Secondary MX (continuity) |
| `A / AAAA` | Per-MX host | IPv4 + IPv6 resolution |
| `SPF` | `v=spf1 mx a ip4:203.0.113.10 ip6:2001:db8:0:1::/64 include:_mailcust.provider.example -all` | Authorised senders |
| `DKIM` | `v=DKIM1; k=rsa; p=<pubkey>` at `mail._domainkey.<domain>` | Signing key (RSA 2048-bit) |
| `DMARC` | `v=DMARC1; p=quarantine; sp=quarantine; adkim=r; aspf=r; rua=mailto:dmarc-agg@example.org; ruf=mailto:dmarc-fail@example.org; pct=100` | Policy + reporting |
| `TLSA` | `3 1 1 <sha256-of-spki>` at `_25._tcp.<mx-hostname>` | DANE certificate binding |
| `MTA-STS` | `v=STSv1; id=<timestamp>` at `_mta-sts.<domain>` | MTA-STS version token |
| `TLS-RPT` | `v=TLSRPTv1; rua=mailto:tlsrpt@example.org` at `_smtp._tls.<domain>` | TLS failure reporting |
| `CAA` | `0 issue "letsencrypt.org"` | Certificate Authority restriction |
| `DNSSEC` | Managed by registrar | TLSA chain of trust |

---

## TLSA / DANE — the renewal challenge

### How `3 1 1` works

The TLSA record `3 1 1 <hash>` means:

| Field | Value | Meaning |
|---|---|---|
| Usage | 3 | DANE-EE, the certificate *itself* must match, no CA chain needed |
| Selector | 1 | SubjectPublicKeyInfo, hash the **public key**, not the full certificate |
| Matching | 1 | SHA-256 |

Because selector=1 hashes only the **public key** (not the certificate), the
TLSA record remains valid across certificate renewals **as long as the key
does not change**. This is the key insight for maintenance strategy.

### The problem with Let's Encrypt

Let's Encrypt certificates expire after 90 days. Certbot renews at ~60 days
and, by default, **generates a new key on each renewal**. When the key
changes, the TLSA hash changes, and the DNS record must be updated, ideally
*before* the new certificate is deployed.

Two strategies, from simplest to most robust:

---

### Strategy A - Key reuse (production choice, zero maintenance)

Both MX hosts use ECDSA P-256 certificates (`key_type = ecdsa`,
`elliptic_curve = secp256r1`) with `reuse_key = True`. The private key
is never regenerated on renewal, so the TLSA hash is stable for the
lifetime of the key - the DNS record is set once and never touched.

See [`docs/examples/certbot-renewal.conf.example`](examples/certbot-renewal.conf.example)
for the full renewal configuration.

**Computing the TLSA hash (once, at initial setup):**

The hash command works identically for ECDSA and RSA keys — it hashes
the DER-encoded SubjectPublicKeyInfo regardless of key type.

```bash
openssl x509 -in /etc/letsencrypt/live/web-mail.example.org/cert.pem \
    -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 \
  | awk '{print $2}'
```

Publish the result as `3 1 1 <hash>` at `_25._tcp.web-mail.example.org`.
The secondary MX gets its own record at `_25._tcp.mx-secondary.example.org`.

**Cryptographic note:** ECDSA P-256 (`secp256r1`) is consistent with the
ECDH curve preferences in Postfix (`tls_eecdh_strong_curve = prime256v1`)
and Dovecot (`ssl_curve_list = X25519:prime256v1:secp384r1`). The choice
is coherent across the entire TLS stack.

**Trade-off:** the private key never rotates. For SMTP, TLS session
confidentiality comes from ECDHE (ephemeral keys), not from the certificate
key, so a long-lived certificate key does not compromise past session
confidentiality. The risk is limited to impersonation if the key is
extracted. For a small mail platform without a dedicated PKI rotation
procedure, this is the right operational choice.

---

### Strategy B - Automated TLSA update via Infomaniak API

For environments where key rotation is required (compliance, policy),
a certbot deploy hook can update TLSA records automatically via the
Infomaniak DNS API after each renewal.

**Approach:** on cert renewal, the hook computes the SHA-256 hash of the
new public key, calls `POST /1/domain/{id}/dns/record` to add the new
TLSA record, then removes the old one. The Infomaniak API uses Bearer
token authentication; the domain ID is retrieved once via
`GET /1/product?service_name=domain`.

**Timing note (RFC 7671):** the safe rollover sequence is: add new TLSA →
wait for TTL expiry → deploy new cert → remove old TLSA. A simplified
deploy hook (add then remove in the same run) works in practice because
SMTP DANE failures cause deferred delivery (`tempfail`), not permanent
rejection, and a TLSA TTL of 300 s limits the mismatch window.

A deploy hook script for this platform is in development and will be
published after production validation.

---

## SPF - multi-domain strategy

With 12 managed domains, each needs its own SPF record. The critical
constraint is **RFC 7208 §4.6.4: maximum 10 DNS lookups** per SPF
evaluation. Each `include:`, `a`, `mx`, and `ptr` mechanism triggers
a lookup.

**Approach used:**

- Each domain has its own SPF with direct IP literals rather than
  `include:` chains where possible
- The primary MX IP and IPv6 prefix are listed explicitly
- One `include:` for the upstream transactional relay (newsletter / e-commerce platform)
- No `ptr` mechanism (deprecated, expensive, unreliable)
- Hard fail (`-all`) on all domains, no `~all` softfail

**Example record:**

```
v=spf1 mx a ip4:203.0.113.10 ip6:2001:db8:0:1::/64 include:_mailcust.relay.example -all
```

**Verification tool:** `dig TXT <domain> | grep spf` + `spf-tools`
or [mxtoolbox.com/spf](https://mxtoolbox.com/spf.aspx)

---

## MTA-STS

MTA-STS requires two components: a DNS TXT record and a policy file
served over HTTPS.

**DNS record** at `_mta-sts.<domain>`:
```
v=STSv1; id=20260509120000
```
The `id` is updated whenever the policy file changes. A timestamp
(`YYYYMMDDHHmmss`) is convenient and sortable.

**Policy file** at `https://mta-sts.<domain>/.well-known/mta-sts.txt`:
```
version: STSv1
mode: enforce
mx: web-mail.example.org
mx: mx-secondary.example.org
max_age: 604800
```

`mode: enforce` means sending MTAs that support MTA-STS will refuse to
deliver over unencrypted connections or to unrecognised MX hosts. Prefer
`mode: testing` for the first deployment period (at least 2 weeks) to
monitor `tlsrpt` reports before enforcing.

---

## TLS-RPT

**DNS record** at `_smtp._tls.<domain>`:
```
v=TLSRPTv1; rua=mailto:tlsrpt@example.org
```

Aggregate JSON reports from sending MTAs are delivered daily to this
address. Reports cover TLS negotiation failures, MTA-STS policy
violations, and DANE failures. Monitoring this mailbox is the primary
signal for certificate / TLSA / MTA-STS misconfiguration.

---

## CAA

```
0 issue "letsencrypt.org"
0 issuewild "letsencrypt.org"
0 iodef "mailto:caa-reports@example.org"
```

Restricts certificate issuance to Let's Encrypt only. Any CA that
encounters this record and is not `letsencrypt.org` must refuse to issue.
The `iodef` entry requests violation notifications (not all CAs honour it).

**Rationale:** a compromised or misissuance event at another CA cannot
produce a valid certificate for these domains. Combined with DANE, this
means a valid SMTP TLS session requires both a matching TLSA record in
DNSSEC-signed DNS *and* a certificate from the correct CA.

---

## DNSSEC

DNSSEC is managed at the registrar level. It is a prerequisite for DANE,
without DNSSEC, TLSA records have no cryptographic binding and DANE
provides no security guarantee.

Verify the chain: `delv @8.8.8.8 _25._tcp.web-mail.example.org TLSA +rtrace`

A `; fully validated` result confirms the TLSA record is covered by a
valid DNSSEC chain.

---

*See also:* [`hardening-decisions.md`](hardening-decisions.md) for the
rationale behind DANE + MTA-STS co-deployment and the key-reuse vs.
key-rotation trade-off.
