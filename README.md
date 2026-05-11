# postfix-rspamd-hardened-config

> Hardened Postfix + Dovecot + Rspamd configuration set for a small
> production mail platform with primary and secondary MX, full
> SPF/DKIM/DMARC/ARC chain, DANE + MTA-STS, postscreen, milter-based
> Rspamd integration, and tuned anti-spam policies. Continuously
> maintained since 2001 (sendmail → Postfix in 2003, then through
> SpamAssassin → Rspamd and Spamhaus → Spamhaus DQS migrations → Abusix).

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Docs: CC-BY-SA 4.0](https://img.shields.io/badge/docs-CC--BY--SA%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by-sa/4.0/)
[![Postfix](https://img.shields.io/badge/postfix-3.x-1f425f.svg)](#)
[![Rspamd](https://img.shields.io/badge/rspamd-3.x-1f425f.svg)](#)

---

## Why this repository exists

This is the configuration set of a small production mail platform that
I have administered in autonomy since 2018 (the configuration lineage
goes back to 2001, several rewrites and migrations later - see
[`docs/real-incidents.md`](docs/real-incidents.md) for the migration
history). It serves a 24/7 e-commerce activity with international
exchanges, processes ~170 messages per day, and has run with **zero
security incidents** and **zero blacklisting** over its lifetime.

The platform's architecture is documented in the companion repository
[`Lionel-Rousseau/laflanelle-secops-architecture`](https://github.com/Lionel-Rousseau/laflanelle-secops-architecture).
The backup chain that protects this stack lives in
[`Lionel-Rousseau/linux-prod-backup-toolbox`](https://github.com/Lionel-Rousseau/linux-prod-backup-toolbox).

## Headline posture

- **Postscreen + DNSBL screening** in front of `smtpd`, with custom
  reply maps and a curated CIDR-based override list for both allowlist
  and reject decisions.
- **Greylisting** (Rspamd module) on top of postscreen, calibrated
  with a low-friction whitelist for known-good senders.
- **Bayes classifier** trained continuously through Sieve scripts
  (`train-ham.sh` / `train-spam.sh`) wired to per-user IMAP folders.
- **Full authentication chain**: SPF (record + Rspamd `policyd-spf`),
  DKIM signing on outbound (Rspamd-managed selectors and keys), DMARC
  with `p=quarantine`, OpenARC 1.0 sealing for through-traffic, and
  validation at receive time.
- **TLS 1.2 minimum** with hardened ciphers (no RSA-only, no SHA1, no
  CBC for TLS 1.2 except mandated suites), DANE on outbound (TLSA
  records), MTA-STS published and enforced.
- **ClamAV milter** for attachment scanning before Rspamd composites.
- **Custom Rspamd settings module** entries (`local.d/perso.conf`)
  that turn off network-based RBLs and Bayes for our own
  `logwatch`-style local cron mail, false-positive churn killer.
- **Geo-blocking + threat-feed aggregation** at the iptables layer
  via `update-datashield.sh`, refreshed daily, giving postscreen a
  cleaner population to deal with.

## What is in this repository

```
postfix-rspamd-hardened-config/
├── README.md                            you are here
├── LICENSE                              MIT for code, CC-BY-SA 4.0 for docs
├── docs/
│   ├── architecture.md                  primary + secondary topology
│   ├── threat-model-mail.md             what we protect against
│   ├── anti-spam-strategy.md            greylisting, RBL choices, Bayes
│   ├── auth-chain.md                    SPF, DKIM, DMARC, ARC, DANE, MTA-STS
│   ├── tls-posture.md                   ciphers, versions, certificates
│   ├── ssh-hardening.md                 actual SSH protection layers
│   └── real-incidents.md                operator history + migration story
├── primary/                             Internet-facing primary MX
│   ├── postfix/                         main.cf, master.cf, maps, .example stubs
│   ├── rspamd/
│   │   ├── local.d/                     ★ all the genuine customisations
│   │   ├── scores.d/                    representative score overrides + README
│   │   └── maps.d/                      curated maps (PII-laden ones replaced
│   │                                    with .example stubs)
│   ├── dovecot/
│   │   ├── conf.d/                      hardening overrides (4 essential files)
│   │   └── sieve/                       Bayes training pipeline
│   ├── scripts/                         postfix-audit.sh, update_rspamd.sh
│   └── openarc.conf                     ARC sealing for relayed traffic
├── secondary/                           secondary MX (relay only)
│   ├── postfix/                         minimal main.cf and master.cf
│   └── README.md
└── fail2ban/                            jails + custom filters + iptables glue
    ├── jail.local
    ├── jail.d/custom.conf
    ├── filter.d/                        only the customised filters (6 of them)
    ├── action.d/                        cloudflare token, ipset-/24 ban
    └── iptables/                        rules + datashield aggregator
```

## Highlights : what to look at first

If you have ten minutes and want to evaluate this work:

1. **[`primary/postfix/main.cf`](primary/postfix/main.cf)** : the heart
   of the configuration. ~970 lines. Read the postscreen section, the
   `smtpd_*_restrictions` chains, and the `tls_*` block.
2. **[`primary/rspamd/local.d/rbl.conf`](primary/rspamd/local.d/rbl.conf)**
   : RBL choices and rationale (Spamhaus → Abusix migration, see the
   incident notes).
3. **[`primary/rspamd/local.d/perso.conf`](primary/rspamd/local.d/perso.conf)**
   : the custom settings module entry that solves the logwatch
   false-positive problem. Small but illustrative.
4. **[`primary/rspamd/scores.d/`](primary/rspamd/scores.d/)** : four
   tuned score-override files representative of the calibration
   pattern; see the directory's README for the procedure.
5. **[`fail2ban/jail.local`](fail2ban/jail.local)** + **[`fail2ban/jail.d/custom.conf`](fail2ban/jail.d/custom.conf)**
   : the actual jail configuration, with custom postfix-related filters.
6. **[`primary/scripts/postfix-audit.sh`](primary/scripts/postfix-audit.sh)**
   : operational maturity signal: an audit script that walks the
   configuration looking for common misconfigurations.
7. **[`docs/real-incidents.md`](docs/real-incidents.md)** : the
   operator's notebook. Three migrations, two outages avoided, and
   one near-miss with a DNSBL provider deprecation.

## Anonymisation notes

This repository is published from a real production codebase. Hostnames,
IP addresses, domain names, user names, paths, and email addresses have
been replaced with documentation placeholders (`example.org`,
`example.net`, `192.0.2.0/24`, `2001:db8::/32`, `admin@example.org`).
The control flow, hardening choices, scoring decisions, and operational
patterns are unchanged.

Files that contained personal or operational data that does not belong
in a public repo (the actual `sender_checks`, `transport`, `rbl_override`,
DKIM whitelist maps, etc.) have been replaced with `*.example` files
that describe the format and provide illustrative entries - see those
files for the operator's guidance on how to maintain them.

## What is NOT in this repository

By design:

- **DKIM private keys** (`/var/lib/rspamd/dkim/*.key`). The setup
  procedure is documented in `local.d/dkim_signing.conf`; the keys
  themselves are never published, even rotated ones.
- **The Postfix `sender_checks` and `transport` maps** in their
  production form, they contain real partner email addresses and
  domain routing that constitute personal data. Replaced with
  `.example` files that show the format and the operator's procedure.
- **The 1700-line CIDR `rbl_override` allowlist** : same reason. The
  `.example` file documents the format and the audit procedure.
- **Dynamic threat feeds** under `iptables/ipset/rules.v4` (~2.6 MB of
  refreshed-daily abuse-IP lists). Not configuration, output of
  `update-datashield.sh`, published only in source form.
- **Stock vendor files** from Debian/Ubuntu (`/etc/fail2ban/filter.d/`
  defaults, `/etc/postfix/post-install`, etc.). The published filter
  set is curated to the ones with operator-authored customisations,
  about 6 files out of the ~140 that ship with the distribution.
- **The Rspamd `modules.d/` tree** : 56 files in stock form on the
  production host, all of which are vendor defaults overridden by the
  `local.d/` files that ARE published here.
- **Several legacy milter configs** (`opendkim.conf`, `opendmarc.conf`)
  that the platform no longer uses, DKIM signing and DMARC validation
  are now handled inside Rspamd. These configs are mentioned for
  historical context in [`docs/real-incidents.md`](docs/real-incidents.md)
  but not bundled here.

## On the production of this repository

The configuration set described here has been maintained in production
since 2001 (across migrations from sendmail to Postfix, SpamAssassin
to Rspamd, and several DNSBL providers). The configuration choices,
threat-model decisions, and operational patterns are the author's,
accumulated over twenty-five years of running mail infrastructure.
The work of distilling, anonymising, restructuring, and documenting
these artefacts for public release was assisted by Claude (Anthropic).
Every file was reviewed and validated by the author before publication.

## License

- Source code (scripts): [MIT](LICENSE)
- Configuration files and documentation: [CC-BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)

## About

Maintained by **Lionel Rousseau** - Linux administrator and SecOps
practitioner, CompTIA Security+ and CySA+ certified.
[`lionel@rousseau.kr`](mailto:lionel@rousseau.kr) ·
[LinkedIn](https://www.linkedin.com/in/lionel-rousseau-kr/) ·
[GitHub](https://github.com/Lionel-Rousseau).
