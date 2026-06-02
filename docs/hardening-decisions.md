# Hardening decisions

This document explains the non-obvious security and architectural choices made in this configuration. The goal is to record the *why* behind decisions that might otherwise look like omissions, misconfiguration, or unnecessary complexity.

---

## TLS policy on port 25: `may`, not `encrypt`

**Setting:** `smtpd_tls_security_level = may`

Requiring TLS (`encrypt`) on port 25 would reject all inbound mail from MTAs that do not support STARTTLS, a significant fraction of legitimate servers (legacy infrastructure, small ISPs, servers in regions with low TLS adoption). The accepted practice for MTA-to-MTA SMTP on port 25 is to *offer* TLS opportunistically and let DANE enforce it on a per-destination basis on the outbound side.

The actual TLS enforcement strategy here is:
- **Inbound port 25:** `may` : accept from all, opportunistically upgrade to TLS
- **Outbound:** `smtp_tls_security_level = dane` : enforce TLS with certificate validation when the remote domain publishes TLSA records in DNSSEC-signed DNS; fall back to opportunistic TLS otherwise

This combination provides strong outbound TLS guarantees without breaking inbound compatibility.

---

## `milter_default_action = accept`

**Setting:** `milter_default_action = accept`

If any milter in the chain (Rspamd, OpenDKIM, OpenDMARC, OpenARC) becomes temporarily unreachable, Postfix falls back to accepting mail rather than deferring it. The alternative (`tempfail`) would queue all inbound mail during a milter restart or crash, creating a backlog and potential delivery delays for a 24/7 e-commerce operation.

The trade-off is accepted: a brief Rspamd outage lets some spam through rather than blocking all inbound delivery. Rspamd is monitored and set to auto-restart (`systemd` + `AutoRestart` in OpenARC config). The iptables datashield layer provides a first-pass filter that is independent of the milter chain.

---

## RBL provider: Abusix Mail Intelligence over Spamhaus DQS

Spamhaus DQS was evaluated and trialled but retired from this configuration for two reasons:

1. **False positive on a known partner domain** : a legitimate commercial partner's sending IP was listed, causing delivery failures that required manual whitelisting and monitoring overhead.
2. **Cost disproportionate to traffic volume** : at 150/200 messages/day, the per-query pricing of Spamhaus DQS is not justified compared to Abusix Mail Intelligence, which offers equivalent coverage with better accuracy for this traffic profile.

Abusix zones in use:

| Zone | Postfix context | Rspamd context | Purpose |
|---|---|---|---|
| `black` | postscreen `*2` | - | Known spam sources |
| `exploit` | postscreen `*2` | - | Exploited/compromised hosts |
| `dynamic` | postscreen `*1` | - | Dynamic/residential IPs |
| `dblack` | `reject_rhsbl_helo/sender` | `RBL_AMI_DBLACK` | Domain-based blacklist |
| `noip` | - | `RBL_AMI_NOIP` | IPs with no PTR record |
| `nod` | - | `RBL_AMI_NOD` | Newly observed domains |
| `authbl` | `master.cf` (587/465) | - | Authenticated spam senders |

---

## Abusix `authbl` on submission ports 587/465

**Setting:** `reject_rbl_client <ABUSIX-API-KEY>.authbl.mail.abusix.zone` in `smtpd_relay_restrictions` on both submission ports, evaluated *before* `permit_sasl_authenticated`.

The standard approach (`permit_sasl_authenticated, reject`) allows any client with valid credentials to submit mail. The `authbl` zone lists IPs that are known to be used for authenticated spam campaigns, compromised accounts, credential-stuffed logins. Checking this zone before the SASL permit means that even a valid username/password is not sufficient if the connecting IP is actively used for spam submission at the time of connection.

This pre-authentication RBL check is specific to the submission ports and not applied on port 25 (where SASL is not the relevant control).

---

## FFDHE4096 DH parameters

**Setting:** `smtpd_tls_dh1024_param_file = /etc/postfix/ffdhe4096.pem`

The parameter name (`dh1024`) is a historical Postfix misnomer that has not been renamed for backwards compatibility. The actual file is a 4096-bit Finite-Field Diffie-Hellman parameter set generated from the RFC 7919 `ffdhe4096` named group, replacing the weak 512-bit and 1024-bit DH parameters that ship with older Postfix/OpenSSL installations.

This mitigates Logjam-class downgrade attacks (CVE-2015-4000) where a MITM forces a TLS connection to use 512-bit export-grade DH, enabling real-time decryption.

---

## Inbound cipher grade: `medium`, outbound: `high`

**Settings:** `smtpd_tls_ciphers = medium` (inbound), `smtp_tls_ciphers = high` (outbound)

Using `high` grade for inbound (port 25) would reject connections from MTAs that only support 128-bit ciphers, still common on older infrastructure. `medium` includes AES-128-GCM and ChaCha20, which are secure; it merely adds tolerance for peers that cannot negotiate AES-256.

On the outbound side, `high` is safe: we control the TLS negotiation and can afford to prefer the strongest available cipher. Peers that cannot negotiate a high-grade cipher will fall back to opportunistic TLS per the `dane` policy.

---

## DANE + MTA-STS: both, not either

DANE (via TLSA records in DNSSEC) and MTA-STS serve the same goal, prevent STARTTLS downgrade attacks but through different mechanisms:

- **DANE** requires DNSSEC on both sides. Provides cryptographic proof of the TLS certificate via DNS. Zero reliance on the CA ecosystem.
- **MTA-STS** works over HTTPS with a cached policy file. Does not require DNSSEC. Protects senders whose DNS resolver does not validate DNSSEC.

Publishing both means that senders supporting DANE get the stronger guarantee, while senders with MTA-STS-capable (but not DNSSEC-aware) MTAs still benefit from downgrade protection. They are complementary, not redundant.

---

## ARC sealing under a single infrastructure domain

**Setting (openarc.conf):** `Domain example.org` for all 13 managed domains.

ARC (Authenticated Received Chain) seals are added by the *infrastructure operator*, not by the sending domain. The seal attests that *this server* evaluated the authentication results, regardless of which of the 13 domains sent the message. Using a single ARC domain simplifies key management (one key to rotate per year) and is the correct interpretation of RFC 8617 for a shared-infrastructure deployment.

DKIM signatures remain per-domain via OpenDKIM (separate milter), which is the relevant identifier for SPF/DKIM/DMARC alignment checks.

---

## Secondary MX: no Rspamd, no Dovecot, no milters

The secondary MX (`mx-secondary.example.org`) is a relay-only continuity host. It deliberately omits the anti-spam and delivery stack:

- **No Rspamd:** filtering happens on the primary when the secondary forwards the queued mail. Running Rspamd on the secondary would add complexity, a second set of Bayes/fuzzy data to maintain, and a second attack surface — for a host whose entire purpose is to queue mail during primary outages.
- **No Dovecot / virtual mailbox:** no local delivery, no IMAP exposure.
- **No milters:** no DKIM signing, no ARC sealing on relay. Mail relayed by the secondary will be re-processed by the full milter chain on primary upon delivery.

The secondary has deliberately relaxed sender restrictions (`reject_unknown_reverse_client_hostname` omitted) to maximise acceptance during a primary outage. The primary re-filters everything on delivery.

`maximal_queue_lifetime = 15d` (vs. Postfix default of 5 days) ensures mail is not silently discarded during extended primary outages.

---

## `reject_sender_login_mismatch` on primary only

**Setting:** present in `smtpd_sender_restrictions` on primary, absent on secondary.

This check rejects authenticated submissions where the SASL login does not match the envelope `From:` address — preventing users from sending as another user. It only makes sense where SASL authentication is active (primary, ports 587/465). On the relay-only secondary there are no SASL users, so the check would never trigger and is omitted.

---

## `reject_private_mx.cidr` in recipient restrictions

Mail from a sender whose MX record resolves to a private/RFC 1918 IP is almost certainly forged or misconfigured. A legitimate internet domain would never publish a private IP as its MX. This check (`check_sender_mx_access cidr:/etc/postfix/reject_private_mx.cidr`) is applied on both primary and secondary as a baseline sanity filter that adds no false-positive risk.
