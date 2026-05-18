# Pricing — math, sources, and what the number actually means

This doc explains exactly how the `$` figure in the status line is computed, where the rates come from, and the limits of that number. If you only read one section, read **[What this number is not](#what-this-number-is-not)**.

## The five token categories

Every Anthropic API request — which Claude Code makes on your behalf — produces a `usage` object that splits tokens into five buckets, each billed at a different rate:

| Bucket | What it represents | Approximate cost (vs. plain input) |
|---|---|---|
| `input_tokens` | Fresh tokens sent to the model that **weren't** served from cache | 1.00× (the baseline) |
| `output_tokens` | Tokens the model generated in its response | ~5.00× input |
| `cache_read_input_tokens` | Tokens served from a previously created prompt cache | ~0.10× input |
| `cache_creation_input_tokens` (5m ephemeral) | Tokens written to a 5-minute prompt cache | ~1.25× input |
| `cache_creation_input_tokens` (1h ephemeral) | Tokens written to a 1-hour prompt cache | ~2.00× input |

Anthropic publishes the absolute rates per model family on [anthropic.com/pricing](https://www.anthropic.com/pricing). This script embeds the current Claude 4.x rates in the `$prices` hashtable near the top of `statusline-tokens.ps1`.

### Embedded rate table (USD per 1M tokens)

| Family | `input` | `output` | `cacheRead` | `cacheW5m` | `cacheW1h` |
|---|---|---|---|---|---|
| Opus 4.x   | $15.00 | $75.00 | $1.50 | $18.75 | $30.00 |
| Sonnet 4.x |  $3.00 | $15.00 | $0.30 |  $3.75 |  $6.00 |
| Haiku 4.x  |  $1.00 |  $5.00 | $0.10 |  $1.25 |  $2.00 |

These are stable as of the script's release. If Anthropic publishes new rates, update `$prices` and you're done — no other change needed.

## The per-turn formula

For every assistant turn in a transcript, the script computes:

```
cost = ( input_tokens                      * price.input
       + output_tokens                     * price.output
       + cache_read_input_tokens           * price.cacheRead
       + ephemeral_5m_input_tokens         * price.cacheW5m
       + ephemeral_1h_input_tokens         * price.cacheW1h
       ) / 1_000_000
```

`price` is looked up from `$prices` using the turn's own `message.model` value — so a session that includes some Haiku triage and some Opus reasoning gets the right blended total.

### Model → family resolution

| `message.model` matches… | uses `$prices` entry |
|---|---|
| `*opus*`   | `opus`   |
| `*sonnet*` | `sonnet` |
| `*haiku*`  | `haiku`  |
| anything else | `opus` (conservative fallback — over-estimates rather than under) |

If you use a non-Claude model via a proxy that still writes Claude-compatible `usage` blocks, add an entry to `$prices` and a branch to `Get-ModelFamily`.

### Cache-write 5m vs 1h split

Modern transcripts (Claude Code 2.1+) split the `cache_creation_input_tokens` total into:

```json
"cache_creation": {
  "ephemeral_5m_input_tokens": 0,
  "ephemeral_1h_input_tokens": 12509
}
```

The script reads both and prices them separately. The 1h ephemeral cache costs 1.6× the 5m rate, so this distinction matters at high cache volume.

**Fallback:** If the breakdown is missing (older transcripts), the bulk `cache_creation_input_tokens` is priced entirely at the **5m rate**. The 5m rate is the API default and the cheaper of the two — i.e. the script slightly *under*-estimates cost in this fallback case rather than over-estimating. If you want a conservative over-estimate instead, swap the fallback to use `cacheW1h` in the script.

## What this number is not

> **The `$` in your status line is not your bill.**

Two ways it can diverge from reality:

1. **You're on a subscription.** Claude Pro, Max, team, and enterprise plans are flat monthly. The dollar figure here is the API-equivalent value of your activity — i.e. what an API customer would have paid to do the same work. Useful for comparison and as an intensity gauge; not actually charged.
2. **The cache-write fallback rounds down.** If your transcripts are from an older Claude Code version without the 5m/1h breakdown, cache writes are charged at the 5m rate. Real-world workloads use both, so the bulk-fallback figure is typically 5–20% low.

It's also not a quota indicator. The **percentages** in the status line are the authoritative number for "am I about to hit a rate limit." The dollar figure is an *activity* signal — useful for noticing "this session has been wildly expensive" or comparing two approaches, not for predicting when you'll get throttled.

## Stats — what typical sessions cost

Approximate cost-per-token for common workloads on **Opus 4.x**:

| Workload shape | Typical mix | Effective rate per 1M tokens |
|---|---|---|
| Light Q&A, short responses | 70% input, 30% output | ~$33 |
| Code generation, long output | 40% input, 60% output | ~$51 |
| Multi-turn agentic work, heavy cache | 5% input, 5% output, 80% cache-read, 10% cache-write | ~$5 |
| Brand-new long context, no cache yet | 50% input, 10% output, 40% cache-write 5m | ~$15 |
| **Real Claude Code session, heavy tool use** | ~0% input, ~1% output, ~96% cache-read, ~3% cache-write | **~$3** |

Cache-heavy agentic workloads are dramatically cheaper per token than fresh-context Q&A. This is why a `147M tok / $414` 5-hour window on Opus is plausible: cache-read tokens dominate, and they're billed at 1/10 the input rate.

### Why the dollar number is so big

A real Claude Code session breakdown looks like this:

```
input:        32k       0.0%     $0.48
output:       1.2M      0.8%     $88
cache_read:   141.7M    96.4%    $213    ← bulk of the bill
cache_w 5m:   736k      0.5%     $14
cache_w 1h:   3.3M      2.2%     $99
                                 ────
                                 $414
```

96% of the tokens are **cache replays of the same conversation context**, billed every turn. The *actual fresh work* — content the model truly hasn't seen — is the 32k input + 1.2M output + 4M cache writes = ~5M tokens. The other 142M is Anthropic re-billing the cached context on every assistant turn at the (discounted) cache-read rate.

This is unavoidable in any multi-turn agent system: each turn re-sends the full conversation. Without prompt caching, the same workload would be **10× more expensive** (input rate instead of cache-read rate). With caching, you pay $2.50–3.00 per million effective tokens. Without caching, you'd pay $15–20.

The good news: this is the most efficient possible way to spend Opus tokens. The bad news: the total still adds up fast because of the sheer volume of replays.

If you're on a flat-rate subscription (Pro / Max / Team / Enterprise), none of this is what you actually pay — see the "What this number is not" section above.

## FAQ

**Why does my `ctx` number not match the cost?**
`ctx` shows the last assistant turn's `input + cache_read + cache_creation` tokens — i.e. roughly "how much of the context window is currently in play." It's a snapshot, not a sum across the window, and the cost field doesn't reflect it.

**What about thinking tokens?**
Extended-thinking output is included in `output_tokens` by Anthropic's accounting, so it's priced correctly without any special handling.

**What about server-tool tokens (web search, web fetch)?**
Anthropic prices those separately from the standard four buckets. They're not tracked by this script. For most Claude Code sessions they're a rounding error, but if you do heavy web-search work, treat the displayed cost as a slight under-estimate.

**How do I update prices when Anthropic changes them?**
Open `statusline-tokens.ps1`, find the `$prices = @{...}` block, edit the numbers, save. No restart needed — the next render picks up the new rates. Wipe `~/.claude/statusline-tokens.cache.json` if you want the change to take effect on the *current* 20-second cache window.

**Why is Opus the fallback for unknown models?**
Opus is the most expensive Claude family. Falling back to it over-estimates cost for unknown models rather than under-estimating — a less surprising failure mode for someone who's actually monitoring spend.

## Sources

- [Anthropic API pricing](https://www.anthropic.com/pricing) — authoritative current rates
- [Prompt caching documentation](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) — explains 5m/1h ephemeral semantics
- [`ccusage`](https://github.com/ryoppippi/ccusage) — original implementation of per-turn, per-model, with 5m/1h split (this script borrows the approach)
