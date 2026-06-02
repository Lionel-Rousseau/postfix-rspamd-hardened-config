#!/usr/bin/env bash
# =============================================================================
# update-datashield.sh - daily IP threat-feed aggregator
#
# Downloads the Data-Shield IPv4 blocklist, atomically swaps it into a live
# ipset, and persists the result. Designed to run via cron (e.g. daily at 03:00).
#
# The ipset "datashield" is referenced by an iptables INPUT rule that drops
# matching source IPs before they reach Postfix postscreen. This provides a
# first-pass filter independent of the milter chain.
#
# Requires: curl, ipset, iptables
# Run as: root (or with CAP_NET_ADMIN)
# =============================================================================
set -euo pipefail

URL="https://raw.githubusercontent.com/duggytuxy/Data-Shield_IPv4_Blocklist/main/prod_data-shield_ipv4_blocklist.txt"
TMP_FILE="$(mktemp)"
TMP_SET="datashield_tmp"
LIVE_SET="datashield"

cleanup() {
  rm -f "$TMP_FILE"
  ipset destroy "$TMP_SET" 2>/dev/null || true
}
trap cleanup EXIT

# Download blocklist
curl -fsSL "$URL" -o "$TMP_FILE"

# Populate a temporary set.
# hash:net handles both plain IPs and CIDR entries — the source feed may
# include either format; hash:ip would crash on CIDR entries with set -e.
ipset create "$TMP_SET" hash:net family inet hashsize 4096 maxelem 262144 -exist
ipset flush  "$TMP_SET"

while IFS= read -r ip; do
  [[ -z "$ip" ]]    && continue
  [[ "$ip" =~ ^# ]] && continue
  # Reject malformed lines (non-IP/CIDR content, stray headers, etc.)
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || continue
  ipset add "$TMP_SET" "$ip" -exist
done < "$TMP_FILE"

# Atomic swap: replace live set without a gap in coverage.
# Both sets must be hash:net — see migration note below if upgrading from hash:ip.
ipset create "$LIVE_SET" hash:net family inet hashsize 4096 maxelem 262144 -exist
ipset swap "$TMP_SET" "$LIVE_SET"
ipset destroy "$TMP_SET" 2>/dev/null || true

# Persist: save datashield + any other named sets needed at boot
mkdir -p /etc/ipset
ipset save | grep -E '^(create|add) (datashield|unbound_allow_v4|unbound_allow_v6)( |$)' \
  > /etc/ipset/rules.v4
