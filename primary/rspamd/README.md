# Rspamd score overrides : `scores.d/`

This directory contains the per-group score overrides that calibrate
the false-positive vs detection-rate tradeoff for the platform.

## What is published here

Four representative files, each illustrating a different calibration
pattern:

| File                       | What it tunes                                              |
|----------------------------|------------------------------------------------------------|
| `hfilter_group.conf`       | Hostname / DNS-based heuristics (PTR, HELO, etc.)          |
| `policies_group.conf`      | DMARC / SPF / DKIM action thresholds                       |
| `rbl_group.conf`           | DNS blacklist composite scoring (the workhorse)            |
| `surbl_group.conf`         | URL-based reputation scoring                               |

## Why only four

The full production deployment carries roughly fourteen `*_group.conf`
files in this directory, one per Rspamd symbol group (content,
fuzzy, headers, mime_types, mua, phishing, statistics, subject,
url_suspect, whitelist, plus the four kept here). The structure is
identical across all of them: a list of symbols with custom score
values that override the upstream defaults.

Publishing the four most operationally significant files demonstrates
the calibration pattern without padding the repository with eleven
near-identical files that would dilute rather than clarify. The other
ten follow the same pattern with values tuned to specific symbol
families.

## How a score override file is structured

Every file in this directory has the same shape:

```hocon
group "<group-name>" {
  symbols = {
    "SOME_SYMBOL_NAME" {
      score = 2.5;        # override of the upstream default
      description = "Explanation of why this score, not the default";
      group = "<group-name>";
    }
    "ANOTHER_SYMBOL" {
      score = -1.0;       # negative = signal of legitimacy
    }
  }
}
```

The values come from operator experience, not from the upstream
recommendations. Two examples of the kind of decisions encoded here:

- `RBL_DNSWL_HI` (DNSWL trusted-sender high confidence) is given
  `-2.0` in `rbl_group.conf` rather than the upstream default
  `-1.0`, because we have observed that DNSWL high-confidence
  senders are essentially never false-positives in our traffic
  patterns and the stronger negative score reduces the rare cases
  where a tagged-good sender ends up scored as spam due to
  accumulated minor symbols.
- `HFILTER_HOSTNAME_UNKNOWN` is dialled down from `2.5` to `1.0` in
  `hfilter_group.conf` because we receive a non-trivial volume of
  legitimate mail from senders whose PTR records are non-standard
  (cloud-hosted relays, older corporate setups). Keeping the
  upstream default produced too many false-positives in this
  context.

## Calibration

These files are reviewed quarterly. The procedure is:

1. Pull the last 90 days of Rspamd actions from the SIEM (`add header`
   + `rewrite subject` + `reject` distributions).
2. For each symbol with non-zero firing in that period, plot the
   ratio of "fired alone" vs "fired with other negative symbols".
   Symbols that fire alone and reach the action threshold are
   candidates for score reduction (likely false-positive vector).
   Symbols that never fire alone could be safely raised in score.
3. Review three representative samples per candidate adjustment
   before changing the score (read the actual messages to confirm
   the symbol is firing for the right reason).
4. Apply the change, monitor for two weeks, roll back if the
   false-positive rate visibly worsens.

This procedure is what produces the calibrations encoded in these
files. The values reflect roughly seven years of cumulative
adjustments.
