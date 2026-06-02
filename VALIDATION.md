# Validation commands

Commands to verify the configuration after deployment or modification.
Run as root on the target host.

## Postfix

```bash
# Syntax check
postfix check

# Active non-default settings (primary or secondary)
postconf -n

# Active master.cf services
postconf -M

# TLS configuration effective values
postconf -n | grep tls

# DANE / DNSSEC resolution test
postmap -q "example.com" btree:/etc/postfix/transport 2>/dev/null; \
  dig +dnssec MX example.com
```

## Rspamd

```bash
rspamadm configtest
rspamadm configdump | head -40
```

## Dovecot

```bash
doveconf -n
doveadm auth test user@example.org
```

## OpenDKIM

```bash
opendkim -n -x /etc/opendkim/opendkim.conf
```

## OpenARC

```bash
openarc -n -c /etc/openarc.conf
```

## Fail2ban

```bash
# Full config dump (jails, actions, filters)
fail2ban-client -d

# Active jail list
fail2ban-client status

# Filter test against a log file
fail2ban-regex /var/log/mail.log /etc/fail2ban/filter.d/postscreen-aggr.conf
fail2ban-regex /var/log/fail2ban.log /etc/fail2ban/filter.d/f2b-postfix-subnet.conf
```

## ipset

```bash
# Verify datashield set type and entry count
ipset list datashield | head -10

# Verify postfix-subnet set
ipset list f2b-postfix-net | head -10
```

## TLS end-to-end

```bash
# Check certificate presented by primary MX
echo | openssl s_client -connect web-mail.example.org:25 -starttls smtp \
  2>/dev/null | openssl x509 -noout -subject -issuer -dates

# Check DANE TLSA record
dig TLSA _25._tcp.web-mail.example.org
```
