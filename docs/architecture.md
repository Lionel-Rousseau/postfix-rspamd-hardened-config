# Architecture

## Hosts

| Host                        | Role                                  | OS / Platform     | SSH port | Where     |
|-----------------------------|---------------------------------------|-------------------|----------|-----------|
| `web-mail.example.org`      | Primary MX + IMAP + outbound submit   | Ubuntu 24.04 LTS  | 1622     | OVH - DC1 |
| `mx-secondary.example.org`  | Secondary MX (relay only)             | Ubuntu 24.04 LTS  | 1622     | OVH - DC2 |

The two hosts sit in **different OVH datacentres** (DC). They are not in a
load-balanced pair: the primary handles all live traffic; the secondary
exists for **continuity**, not capacity.

## Service map

```
                      ┌─────────────────────────────────┐
                      │  Internet                        │
                      └──────────────┬───────────────────┘
                                     │
                      ┌──────────────▼──────────────────────┐
                      │  web-mail.example.org  (priority 10)│
                      │  ─────────────────────────────────  │
                      │  iptables (datashield aggregator)   │
                      │   ↓                                 │
                      │  Postfix postscreen :25 / :465      │
                      │   ↓                                 │
                      │  Postfix smtpd                      │
                      │   ↓                                 │
                      │  Rspamd (milter, port 11332)        │
                      │   ↓                                 │
                      │  Postfix queue                      │
                      │   ↓                                 │
                      │  Dovecot LMTP                       │
                      │   ↓                                 │
                      │  /home/vmail/<domain>/<user>/       │
                      └─────────────────────────────────────┘

                      ┌─────────────────────────────────────┐
                      │  mx-secondary.example.org           │
                      │  (priority 20 - backup)             │
                      │  ─────────────────────────────────  │
                      │  Postfix smtpd (relay-only)         │
                      │   ↓                                 │
                      │  Postfix queue (deferred)           │
                      │   ↓ when primary is reachable       │
                      │  smtp client → web-mail:25          │
                      └─────────────────────────────────────┘
```

## DNS records

| Record                                  | Purpose                                     |
|-----------------------------------------|---------------------------------------------|
| `MX  10  web-mail.example.org`          | Primary MX                                  |
| `MX  20  mx-secondary.example.org`      | Secondary MX (continuity)                   |
| `A / AAAA` for each MX                  | IPv4 + IPv6                                 |
| `SPF` (TXT)                             | `v=spf1 mx a ip4:... ip6:... include:upstream-relay.example -all` |
| `DKIM` (TXT, `mail._domainkey`)         | RSA 2048-bit, rotated yearly                |
| `DMARC` (TXT, `_dmarc`)                 | `p=quarantine; sp=quarantine; adkim=r; aspf=r; rua=...; pct=100` |
| `TLSA` (DANE)                           | Per-MX, `3 1 1 <hash>` of leaf cert         |
| `MTA-STS`                               | `mode=enforce`, served via `https://mta-sts...` |
| `_smtp._tls` (TLS-RPT)                  | Aggregate TLS-RPT to a dedicated mailbox    |
| `CAA`                                   | `letsencrypt.org` only                      |

See [`auth-chain.md`](auth-chain.md) for the rationale and rotation
procedures.

## Inbound flow (primary)

1. **iptables** drops connections from the daily-refreshed datashield
   feed (FireHOL Level 1, AbuseIPDB confidence ≥ 90, dshield top
   attackers, assembled by `iptables/update-datashield.sh`).
2. **postscreen** on port 25 enforces:
   - DNSBL pre-greet weight scoring (Abusix Mail Intelligence as primary provider, plus a couple of niche RBLs);
   - PREGREET trap (clients that send before the banner are dropped);
   - HANGUP penalty;
   - allow / deny via `cidr:rbl_override` for the operator override layer.
3. **smtpd** chains, in order: `mynetworks` → `permit_sasl_authenticated`
   → `check_client_access` → `check_helo_access` →
   `check_sender_access` → `reject_unknown_*` → DNSBL fallback.
4. **Rspamd milter** scores the message; the action chain returns one
   of: `reject`, `add header`, `rewrite subject`, `greylist`, `accept`.
   Greylist works through a Redis store, lifetime 1h.
5. Accepted mail goes to the **Postfix queue** then **Dovecot LMTP**
   for final delivery.

## Outbound flow

1. Authenticated submission on **port 587 (STARTTLS)** or **465
   (implicit TLS)** via `smtpd_tls_security_level=encrypt`.
2. Rspamd milter on outbound too. A final filter against accidentally
   forwarding malware in replies, plus DKIM signing via the
   `dkim_signing` module.
3. OpenARC seals a Authentication-Results chain when the message
   transits multiple administrative domains (relay through a
   third-party relay for some destinations).
4. Postfix `smtp` client honours **DANE** (TLSA records) on
   destinations that publish them, and falls back to `dane-only`
   strict where the domain is on our MTA-STS receiver list.

## Secondary (relay-only)

The secondary MX accepts mail when the primary is unreachable, queues
it, and delivers to the primary as soon as it comes back. Configuration
is deliberately minimal, see [`secondary/README.md`](../secondary/README.md)
for the relay-only setup. It does **not** run Rspamd, Dovecot, or any
local user-facing service: those would be liabilities during a
primary-host incident, not assets.
