# Delegation models: what the provider actually serves

Read this **before delegating or starting a pstack workflow**. `AGENTS.md` keeps the policy and the
gate; this file keeps the table and the price arithmetic, because it is needed only when a model id
has to be chosen, not on every session start.

## Allowed

**Provider is `routerai` (`https://routerai.ru/`) since 2026-11-17.** Every default in
`settings.json` and `pi-pstack-adapter.json` carries the `routerai/` prefix; `openrouter/` is no
longer default and its ids are blocked by policy.

Only these ids, on `routerai/`. The table below is the **OpenRouter list read on 2026-11-16** and is
kept as history — it explains why these 14 ids were chosen under the workspace cap. It is **not**
the routerai price list; the routerai figures are in the next section.

| id | in | **cache read** | out | role |
| --- | --- | --- | --- | --- |
| `deepseek/deepseek-v4.1-flash-1017` | 0.30 | **0.006 (2%)** | 1.20 | default for `reviewer` / `oracle` / `evidence-auditor`; bulk code, long tool loops, panel seats |
| `deepseek/deepseek-v4.1-flash` | 0.14 | **0.0042 (3%)** | 0.42 | same model, unversioned |
| `deepseek/deepseek-v4-flash-vision-exp` | 0.44 | 0.014 (3%) | 1.32 | vision experiments |
| `z-ai/glm-5.3` | 0.0699 | **0.0689 (99%)** | 1.40 | `judgment`, `strongest-judgment`, one arena cross-judge seat |
| `z-ai/glm-5.3-flash` | 0.0399 | 0.030 (75%) | 0.0784 | default bulk model: every agent and pstack runner role |
| `z-ai/glm-5.2` | 0.0070 | 0.0060 (86%) | 6.80 | allowed, not assigned; most expensive output in the cap |
| `z-ai/glm-5.1` | 1.40 | 0.26 (19%) | 4.40 | allowed, not assigned |
| `z-ai/glm-5` | 1.00 | 0.20 (20%) | 3.20 | allowed, not assigned |
| `z-ai/glm-4.7-flash` | 0.0605 | 0 | 0.40 | allowed, not assigned |
| `minimax/minimax-m3` | 0.30 | 0.060 (20%) | 1.20 | third family, arena cross-judge seat only |
| `minimax/minimax-m3.1-flash` | 0.15 | 0.015 (10%) | 0.60 | allowed, not assigned |
| `inclusionai/ling-3.1-flash` | 0.045 | 0.0090 (20%) | 0.135 | allowed, not assigned |
| `inclusionai/ling-3.0-flash` | 0.021 | 0.0042 (20%) | 0.063 | allowed, not assigned |
| `inclusionai/ling-3.0-flash-vl` | 0.060 | 0.012 (20%) | 0.18 | vision fallback |

### Rank by cache read, not by input

### routerai prices, read 2026-11-17

`GET https://routerai.ru/api/v1/models` returns `pricing` **per token**; multiply by 1e6 for
$/Mtok. Values below are that endpoint, rounded to 3 decimals.

| id | in | **cache read** | out | cache/input |
| --- | --- | --- | --- | --- |
| `inclusionai/ling-3.0-flash` | 2.253 | **0.451** | 6.758 | 20% |
| `deepseek/deepseek-v4.1-flash` | 16.519 | **0.496** | 49.558 | 3% |
| `deepseek/deepseek-v4-flash-vision-exp` | 23.127 | **0.736** | 69.381 | 3% |
| `minimax/minimax-m3.1-flash` | 8.045 | **0.805** | 32.181 | 10% |
| `deepseek/deepseek-v4.1-flash-1017` | 4.720 | **0.826** | 8.260 | 17.5% |
| `inclusionai/ling-3.1-flash` | 4.827 | **0.965** | 14.481 | 20% |
| `inclusionai/ling-3.0-flash-vl` | 6.758 | **1.352** | 20.274 | 20% |
| `z-ai/glm-5.3-flash` | 4.708 | **3.540** | 9.251 | 75% |
| `minimax/minimax-m3` | 24.672 | **5.363** | 102.978 | 22% |
| `z-ai/glm-5.3` | 7.498 | **7.391** | 150.176 | 98.6% |
| `z-ai/glm-5.1` | 96.542 | **9.654** | 311.079 | 10% |
| `z-ai/glm-5.2` | 60.339 | **11.263** | 193.083 | 19% |
| `z-ai/glm-5` | 64.361 | **12.872** | 205.956 | 20% |
| `z-ai/glm-4.7-flash` | 6.490 | — | 42.907 | none |

Consequences that differ from the OpenRouter arithmetic below:

- The cache discount on routerai is **5.7x** for `deepseek-v4.1-flash-1017`, not 50x, so "deepseek
  is cheap because of caching" no longer carries on its own — it is cheap because input is 4.72 and
  output 8.26, and it still wins on both against `glm-5.3` (7.50 / 150.18).
- `glm-5.3` cache read is 98.6% of input, so caching buys nothing there; that part of the analysis
  still holds.
- `minimax-m3` (24.67 / 102.98) and `glm-5.2` (60.34 / 193.08) are still the expensive seats; keep
  them to one judge or one cross-judge seat.

### OpenRouter arithmetic (historical, 2026-11-11..16)

An agent loop re-sends its whole context every turn: measured over 2026-11-11..16, **97-99% of all
prompt tokens were cache reads**, and prompt cost was 64-83% of the bill. So the price that decides
the bill is the cache-read column, not the headline input price.

| | $/Mtok prompt tokens actually billed | $ per call |
| --- | --- | --- |
| `deepseek-v4.1-flash-1017` | 0.0056 | 0.00078 |
| `glm-5.3` | 0.1163 | 0.00664 |

`glm-5.3` bills cache reads at 99% of its input price, so caching buys nothing there; deepseek
bills them at 2%, a 50x discount. Same workload, **21x** the prompt cost. Consequence: put the
model with a real cache discount on every high-frequency, long-context role, and spend a model
with no cache discount only on single-shot decisions.

Corollary: `z-ai/glm-5.2` (cache 86%, output 6.80) and `minimax/minimax-m3` (cache 20%, output
1.20) are as expensive per call as `glm-5.3` despite cheaper inputs. Do not use them as "the cheap
option" and do not put them in bulk seats.

Provider routing matters too: `deepseek-v4.1-flash-1017` on InferenceNet cost 5x what the same
model cost on DeepInfra ($0.0040 vs $0.00077 per call). Pin `DeepInfra` when the volume is large.

## Re-verify before trusting

The table is a dated observation, not a standing fact. Re-verify after any provider or price
change: read `GET https://routerai.ru/api/v1/models` and send one `max_tokens: 1` request per id.
A 404 is the provider, not local config. (`pi-models-check` no longer exists on this machine.)

```bash
for m in z-ai/glm-5.3-flash deepseek/deepseek-v4.1-flash-1017; do
  curl -s -o /dev/null -w "$m %{http_code}\n" https://routerai.ru/api/v1/chat/completions \
    -H "Authorization: Bearer $ROUTERAI_API_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$m\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
done
```

@see `~/.pi/agent/AGENTS.md` → Delegation model policy (blocked ids, enforcement, rules)
