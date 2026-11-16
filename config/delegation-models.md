# Delegation models: what the provider actually serves

Read this **before delegating or starting a pstack workflow**. `AGENTS.md` keeps the policy and the
gate; this file keeps the table and the price arithmetic, because it is needed only when a model id
has to be chosen, not on every session start.

## Allowed

Only these ids, all on `openrouter/`. Prices below are the OpenRouter list, read from
`GET https://openrouter.ai/api/v1/models` on 2026-11-16; the cap is provider-side, so a model in
the local catalog is not evidence it works.

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

The table is a dated observation, not a standing fact. Run `pi-models-check` (one `max_tokens: 1`
request per id, exit 1 on 404) after a provider or guardrail change. A 404 there is the cap, not
local config.

@see `~/.pi/agent/AGENTS.md` → Delegation model policy (blocked ids, enforcement, rules)
