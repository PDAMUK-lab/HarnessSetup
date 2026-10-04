# Models, offload backends and sub-agents

What else can run on the three model slots, how to switch, which RAM/SSD offload engines are worth a look, and how
the agent's sub-agents are set up. Checked on 2026-10-04 against the Hugging Face API (every file name and size
below exists), llama.cpp master (every architecture below is supported) and Hermes Agent's source.

**Not checked:** none of these models has been run on the GTX 1070, the RX 6600 XT or a V100. Benchmark numbers
are the vendors' own unless marked otherwise. Before you keep a model, run the tool-call smoke test (stage 10 runs
it on the laptop; `./setup.sh tool verify` checks both machines) and the Step 30 task set from the guide.

## How a model plugs in

Each slot is a handful of settings. Change them, then re-run that slot's installer.

| Slot | Settings | Where | Then run |
| --- | --- | --- | --- |
| Laptop (sub-agents, last resort) | `LAPTOP_MODEL_FILE` `_URL` `_ALIAS` `LAPTOP_CHAT_KWARGS` `LAPTOP_SAMPLING` `LAPTOP_CTX` | laptop: `./setup.sh configure --defaults --set KEY=VALUE ...` | `./setup.sh run 10`, then `./setup.sh run 11` if the alias or `LAPTOP_CTX` changed (Hermes's endpoints carry both) |
| Desktop (day) | `DESKTOP_MODEL_FILE` `_URL` `_ALIAS` `DESKTOP_CHAT_KWARGS` `DESKTOP_SAMPLING` `DESKTOP_N_CPU_MOE` | desktop: `.\Configure.ps1 -Set 'KEY=VALUE','KEY=VALUE'` | `.\Install-Llama.ps1` |
| Overnight | `NIGHT_MODEL_FILE` `_URL` `_ALIAS` `NIGHT_CHAT_KWARGS` `NIGHT_SAMPLING` `NIGHT_MTP` `NIGHT_NGL` | desktop | `.\Install-Overnight.ps1` |
| V100 tier | `V100_MODEL_FILE` `_URL` `_ALIAS` `V100_CHAT_KWARGS` `V100_SAMPLING` `V100_MTP` `V100_QUANT` | desktop | `.\Install-V100.ps1` |

- **`*_CHAT_KWARGS`** are the model's chat-template switches as `key=value` pairs separated by commas, for example
  `enable_thinking=true,preserve_thinking=true` (the kit turns them into llama-server's `--chat-template-kwargs`
  JSON). `none` sends nothing; `auto` uses the kit's values for the Qwen model it ships.
- **`*_SAMPLING`** are llama-server sampling flags, for example `--temp 1.0 --top-p 0.95 --top-k 64`. Use the model
  card's values. `none` leaves the server's defaults.
- **`NIGHT_MTP` / `V100_MTP`**: say `0` for a model without a built-in MTP head, or the server will not start. Only the
  Qwen3.8 files have one; `Install-Overnight.ps1` and `Install-V100.ps1` check the downloaded file and leave MTP off
  (with a warning) when it has none.
- **The alias** is the name Hermes uses. A drop-in of the same model can keep the old alias and nothing else
  changes. For a different model, give it its own alias on **both** machines (`DESKTOP_MODEL_ALIAS`,
  `NIGHT_MODEL_ALIAS` and `V100_MODEL_ALIAS` are shared settings), then on the laptop run `./setup.sh run 11` (day and
  laptop models, the V100 tier) or `./setup.sh tool overnight-laptop` (the overnight model) so Hermes's endpoints and
  fallback chain use the new name. An overnight job keeps the model it was created with: change it on the dashboard's
  Cron page, or delete the job and run `overnight-laptop --task ...` again.
- Quote a value that holds spaces (or, in PowerShell, commas): `--set 'LAPTOP_SAMPLING=--temp 1.0 --top-p 0.95 --top-k 64'`
  in bash, `-Set 'DESKTOP_CHAT_KWARGS=enable_thinking=true,preserve_thinking=true'` in PowerShell.

## Uncensored drop-ins (same model, refusals removed)

Same architecture, size class and chat template as the kit's defaults, so only the file and URL change. These are
community edits of the weights; the numbers are the uploaders' own measurements.

> With passwordless sudo, approvals off (`APPROVAL_MODE=off`) and an uncensored model, nothing in the loop
> refuses anything. Keep the laptop on its own network segment (guide Step 28) and review every PR.

| Slot | Repo / file | Size | Method and evidence |
| --- | --- | --- | --- |
| Laptop | `llmfan46/Qwen3.5-9B-ultra-uncensored-heretic-GGUF` / `Qwen3.5-9B-ultra-uncensored-heretic-v2-Q5_K_M.gguf` | 6.42 GB | Heretic (ARA): 4/100 refusals against 86/100 for the original, KL divergence 0.0241 |
| Desktop | `llmfan46/Qwen3.6-35B-A3B-uncensored-heretic-GGUF` / `Qwen3.6-35B-A3B-uncensored-heretic-Q5_K_M.gguf` | 24.76 GB | Heretic (magnitude-preserving ablation): 10/100 against 83/100, KL 0.0015 |
| Overnight / V100 | `JonathanColetti/Qwen3.8-27B-Uncensored-GGUF` / `Qwen3.8-27B-Uncensored-Q4_K_M.gguf` (V100: `-Q5_K_M`, 19.54 GB) | 16.81 GB | Heretic; refusals "substantially reduced, not eliminated"; the MTP head is kept inside the file, so `NIGHT_MTP=1` works |

Runners-up: laptop `mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF` `Huihui-Qwen3.5-9B-abliterated.Q5_K_M.gguf`
(6.52 GB, no published numbers); desktop `HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive`
`...-Q4_K_M.gguf` (21.17 GB, claims 0/465 refusals, method not published, no Q5); overnight
`huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF` `Huihui-Qwen3.8-27B-abliterated-UD-Q4_K_XL.gguf` (17.38 GB, built on
Unsloth's quant; the card calls the method crude; if the night server refuses the MTP flags, set `NIGHT_MTP=0`).

Laptop, for example:

```bash
./setup.sh configure --defaults \
  --set LAPTOP_MODEL_FILE=Qwen3.5-9B-ultra-uncensored-heretic-v2-Q5_K_M.gguf \
  --set LAPTOP_MODEL_URL=https://huggingface.co/llmfan46/Qwen3.5-9B-ultra-uncensored-heretic-GGUF/resolve/main/Qwen3.5-9B-ultra-uncensored-heretic-v2-Q5_K_M.gguf
./setup.sh run 10
```

Desktop: `.\Configure.ps1 -Set 'DESKTOP_MODEL_FILE=<file>','DESKTOP_MODEL_URL=https://huggingface.co/<repo>/resolve/main/<file>'`, then `.\Install-Llama.ps1`.

## Other model families

Ranked by expected agentic-coding quality within each slot's fit. "Uncensored" names a refusal-removed copy of the
same model where one exists.

### Laptop (fully in 8 GB of Pascal VRAM, context cache in RAM)

| Model | File (size) | Settings besides file/URL/alias | Notes |
| --- | --- | --- | --- |
| **Ornith 1.5 9B** (Qwen3.5-9B with agentic-coding RL, MIT) | `ornith-ai/Ornith-1.5-9B-GGUF` / `Ornith-1.5-9B-Q5_K_M.gguf` (6.64 GB) | none: same switches and sampling as today | Self-reported SWE-bench Verified 70.6 against 53.2 for Qwen3.5-9B, Terminal-Bench 2.1 46.2 against 21.3. The largest gain in this budget if it holds. Uncensored: `Thunder13240/Ornith-1.5-9B-heretic-GGUF` `Ornith-1.5-9B-heretic-Q5_K_M.gguf` (6.47 GB, 0/100 refusals, KL 0.0376) |
| MiMo-V2.6 Distill 9B (Xiaomi, Qwen3.5-9B base) | `bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF` / `MiMo-V2.6-Distill-Qwen-9B-Q5_K_S.gguf` (6.50 GB) | none | Self-reported Terminal-Bench 2.1 37.1 against 27.0. Its tool calls go through llama.cpp's generic parser, so smoke-test first. An SFT research checkpoint |
| Gemma 4 12B (Google, QAT, Apache-2.0) | `unsloth/gemma-4-12B-it-qat-GGUF` / `gemma-4-12B-it-qat-UD-Q4_K_XL.gguf` (6.72 GB) | `LAPTOP_CHAT_KWARGS=enable_thinking=true` (thinking is off otherwise), `LAPTOP_SAMPLING=--temp 1.0 --top-p 0.95 --top-k 64` | A different family with a small context cache. Weaker at repo-level coding (SWE-bench Verified 44.2 in one shared evaluation). Uncensored: `SC117/gemma-4-12B-it-heretic-QAT-GGUF` `gemma-4-12B-it-heretic-QAT-UD-Q4_K_XL.gguf` (6.72 GB) |
| Granite 4.2 8B (IBM, Apache-2.0) | `ibm-granite/granite-4.2-8b-GGUF` / `granite-4.2-8b-Q5_K_M.gguf` (6.25 GB) | `LAPTOP_CHAT_KWARGS=enable_thinking=true`, `LAPTOP_SAMPLING=--temp 1.0 --top-p 0.95`, **`LAPTOP_CTX=65536`** | Its context cache is about 122 KB per token, so 128K would need 16 GB of RAM. Self-reported SWE-bench Verified 47.7. Uncensored: `richardyoung/granite-4.2-8b-heretic-GGUF` `granite-4.2-8b-heretic-Q5_K_M.gguf` (6.25 GB; 12/100 refusals, KL 0.08) |
| Mellum2 12B-A2.5B Thinking (JetBrains) | `bartowski/Mellum2-12B-A2.5B-Thinking-GGUF` / `Mellum2-12B-A2.5B-Thinking-IQ4_XS.gguf` (6.77 GB) | none | Fastest option (2.5B active), but no SWE-bench results and weaker instruction following |

Not suitable here: gpt-oss (20B is 12 GB), Gemma 4 E4B (too weak), Phi (16K context), LFM2.5 (too few active
parameters), Nemotron and Devstral (too large).

### Desktop (RX 6600 XT 8 GB + 32 GB RAM, experts in RAM, file under about 26 GB)

| Model | File (size) | Settings besides file/URL/alias | Notes |
| --- | --- | --- | --- |
| **Ornith 1.5 35B-A3B** (Qwen3.6 with agentic-coding RL, MIT) | `bartowski/Ornith-1.5-35B-A3B-GGUF` / `Ornith-1.5-35B-A3B-Q5_K_M.gguf` (25.49 GB) | none (bartowski's template keeps `preserve_thinking`) | Self-reported SWE-bench Verified 79 against 73.4, SWE-bench Pro 59.6 against 49.5. Users report very long reasoning and some tool misuse, so A/B it. Uncensored: `dealignai/Ornith-1.5-35B-A3B-UNCENSORED-GGUF` `Ornith-1.5-35B-A3B-CRACK-Q5_K_M.gguf` (25.35 GB) |
| Laguna XS 2.1 (Poolside, 33B-A3B) | `bartowski/Laguna-XS-2.1-GGUF` / `Laguna-XS-2.1-Q5_K_M.gguf` (24.01 GB) | `DESKTOP_CHAT_KWARGS=enable_thinking=true` (required: the template defaults to off), `DESKTOP_SAMPLING=--temp 1.0 --top-k 20 --top-p 1.0` | A different family close to Qwen3.6 on SWE-bench (70.9 against 73.4) but well behind on Terminal-Bench (37.5 against 51.5). Its context cache is about twice Qwen's, so keep all experts in RAM first (`DESKTOP_N_CPU_MOE` = its layer count) and lower it while VRAM allows. License: OpenMDW |
| North Mini Code 1.0 (Cohere, 30B-A3B, Apache-2.0) | `unsloth/North-Mini-Code-1.0-GGUF` / `North-Mini-Code-1.0-UD-Q5_K_XL.gguf` (23.0 GB) | `DESKTOP_CHAT_KWARGS=none`, `DESKTOP_SAMPLING=--temp 1.0 --top-p 0.95`, `DESKTOP_N_CPU_MOE=49` | Built for agentic coding; vendor scores below Qwen3.6 (SWE-bench Verified 67.6). Uncensored: `mradermacher/North-Mini-Code-1.0-Uncensored-Heretic-GGUF` `North-Mini-Code-1.0-Uncensored-Heretic.Q5_K_M.gguf` (21.73 GB) |
| Gemma 4 26B-A4B (Google, Apache-2.0) | `unsloth/gemma-4-26B-A4B-it-GGUF` / `gemma-4-26B-A4B-it-UD-Q6_K_XL.gguf` (23.3 GB) | `DESKTOP_CHAT_KWARGS=enable_thinking=true,preserve_thinking=true`, `DESKTOP_SAMPLING=--temp 1.0 --top-p 0.95 --top-k 64`, `DESKTOP_N_CPU_MOE=30` | Mature llama.cpp/Vulkan support and strong instruction following, but clearly weaker at agentic coding (SWE-bench Verified 57.4 against 70.1, NVIDIA's measurement). Uncensored: `llmfan46/gemma-4-26B-A4B-it-uncensored-heretic-GGUF` `...-Q6_K.gguf` (22.64 GB) |

Not suitable here: Nemotron 3.5 Lightning (weak on SWE-bench), dense 24-30B models (too slow with 8 GB of VRAM),
GLM-5.x and gpt-oss-120b (far too large), architectures not in llama.cpp (Xing4.0, K2-Horizon).

### Overnight (desktop, a few tokens per second is fine) and the V100 tier

| Model | File (size) | Settings besides file/URL/alias | Notes |
| --- | --- | --- | --- |
| Muse Glimmer 30B (Meta, dense, Apache-2.0) | `unsloth/Muse-Glimmer-30B-GGUF` / `Muse-Glimmer-30B-UD-Q4_K_XL.gguf` (15.88 GB); `UD-Q5_K_XL` (21.79 GB) for 2 x 16 GB V100 | `*_CHAT_KWARGS=reasoning_strength=high` (`xhigh` for maximum), `*_SAMPLING=--temp 1.0 --top-p 0.95 --top-k 64`, **`*_MTP=0`** (it uses a separate DFlash drafter, not MTP) | A complement, not a replacement: vendor SWE-bench Pro 51.2 against 61.7 for Qwen3.8-27B. Tiny context cache (about 1.7 GB at 128K), which suits the V100 cards. Needs llama.cpp b11246 or newer. Uncensored: `bartowski/darkc0de_Muse-Glimmer-30B-heretic-GGUF` `darkc0de_Muse-Glimmer-30B-heretic-Q5_K_M.gguf` (20.11 GB) |
| Laguna S 2.1 (Poolside, 118B-A8B) | `unsloth/Laguna-S-2.1-GGUF` / `Laguna-S-2.1-UD-IQ3_XXS.gguf` (44.28 GB) | `V100_CHAT_KWARGS=enable_thinking=true`, `V100_SAMPLING=--temp 1.0 --top-k 20 --top-p 1.0`, `V100_MTP=0`, `V100_VRAM_GB=32` | **2 x 32 GB V100 only.** Vendor scores close to Qwen3.8-27B (Terminal-Bench 2.1 70.2 against 73.0) from a different family, and faster with 8B active, but a 3-bit file loses more than the 27B at Q6/Q8 on the same cards. Install-V100's fit estimate assumes a Qwen-class model; read the server log |
| Laguna XS 2.1 / North Mini Code 1.0 | as in the desktop table | as in the desktop table with `NIGHT_` instead of `DESKTOP_`, plus **`NIGHT_MTP=0`** | Fast MoE options for overnight if speed matters more than the 27B's quality. The night script sets the GPU layers with `NIGHT_NGL`, not an expert split |
| Gemma 4 31B (Google, dense) | `unsloth/gemma-4-31B-it-GGUF` / `gemma-4-31B-it-UD-Q5_K_XL.gguf` (21.89 GB) | `*_CHAT_KWARGS=enable_thinking=true`, sampling as Gemma above, **`*_MTP=0`** | The weakest agentic coder here (SWE-bench Pro 36.9) and a large context cache; only for its mature tooling |

The 27B stays the overnight pick. Qwen fine-tunes of the 27B (Swift, Bonsai and others) were left out as not a new
family. GLM-5.x, gpt-oss-120b and Qwen3-Coder-Next (80B) do not fit; Granite 4.2 30B and Nemotron are weaker.

## RAM and SSD offload engines

People run large models by keeping the experts in RAM or streaming weights from SSD. For these machines the result
is clear: **keep llama.cpp.** It is the only engine that runs on all three GPU families (Pascal, RDNA2 on Windows,
Volta), serves reliable tool calls at 128K, and already has the offload features the specialist engines advertise.

| Engine | Verdict | Why |
| --- | --- | --- |
| llama.cpp (current) | **keep** | `--n-cpu-moe` / `-ot` expert offload works on CUDA and Vulkan; see the tuning list below |
| llama.cpp Windows ROCm build (gfx1032 is a build target) | **try** on the desktop | Same engine, flags and tool calls, so an A/B is cheap: unzip into a separate folder, run the same `llama-bench` line against the Vulkan build, keep it only if it wins by about 10% and passes the tool-call test. Unconfirmed on this card |
| ik_llama.cpp | watch | CPU + CUDA (Turing+) focus; no Vulkan/ROCm, so not for the AMD desktop. Only an option on the V100 tier if layer split disappoints |
| pulsar (2026, SSD expert streaming) | watch | Linux + NVIDIA, builds for Pascal, parses Qwen tool calls; could let the laptop try the 35B-A3B from SSD. Three months old, unproven on 8 GB + 16 GB |
| KVMem llama.cpp, Magnitude | watch | Tiered context cache (with a per-answer token cap) / self-tuning engine whose Vulkan offload is unproven; neither runs on Pascal |
| Colibri | skip | Its Qwen3.6 engine refuses tool calls (HTTP 400) and is slower than llama.cpp on 8 GB cards; its niche is 300B+ models from NVMe at 0.1-2 tokens/s |
| KTransformers, vLLM, SGLang, exllamav3 | skip | None supports Pascal, Volta or RDNA2 on Windows |
| PowerInfer, AirLLM, FlexGen | skip | Own model formats or no server and no tool calls; far too slow for an agent |
| Ollama, LM Studio | skip | Wrap the same engine with less control (no `--n-cpu-moe`, own templates); Ollama needs a newer driver than the laptop's 550 |
| MLC-LLM, moe-l2 | skip | No RAM offload / needs driver 570+ and NVIDIA only |

llama.cpp tuning worth measuring (with `llama-bench` and the Step 30 tasks, one change at a time):

- **Expert split:** sweep `llama-bench -m <35B> -fa 1 -ctk f16 -ctv q8_0 -ncmoe 40,36,32,28 -d 0,32768 -p 2048 -n 128`,
  or let auto-fit choose: leave out `-ngl`/`--n-cpu-moe` (any of them turns fit off) and keep `-c`, or run `llama-fit-params`.
- **Prompt speed:** a larger micro-batch (`-ub 2048`) usually speeds up the long prompts an agent sends, at the cost
  of VRAM; re-check the 7.3 GB target.
- **Speculative decoding:** MTP helps the dense 27B; with experts in RAM it can slow the 35B-A3B down, so measure
  before adding it there. `--spec-type ngram-mod` needs no extra model and helps when the agent rewrites code.
- **SSD paging** (a model larger than free RAM, read through mmap) works but makes generation disk-bound; keep it as
  a safety net, not a plan. `--no-mmap` and `--mlock` are gone from current llama.cpp (now `--load-mode`); the kit
  uses neither.

## Sub-agents

Hermes splits work: the planner hands well-specified pieces to sub-agents (`delegate_task`), which write most of
the code. How the kit sets them up, checked against Hermes's source (`hermes_cli/config_defaults.py`,
`tools/delegate_tool*.py`):

| Profile | Sub-agents run on | Parallel | Fallback |
| --- | --- | --- | --- |
| default (cloud) | `OR_WORKER_MODEL` on OpenRouter | `MAX_CONCURRENT_CHILDREN` (3) | the main chain: OpenRouter fallback model, desktop, laptop |
| `local` | the laptop's model (`delegation.base_url`) | 1 (one llama-server slot) | the desktop endpoints (the planner waits for its sub-agent, so the desktop's slot is free) |
| overnight jobs | the planner is the 27B; its sub-agents follow the `local` profile | 1 | as `local` |

What the kit does about it (since 0.4.0):

- **Fallback for sub-agents.** A sub-agent pinned to a provider or endpoint gets *no* fallback unless
  `delegation.fallback_providers` names one, so an OpenRouter outage used to fail every sub-agent while the planner
  fell back. `lib/chain.sh` now writes that list next to the main chain, and `hermes-desktop off` removes the
  desktop from it like everywhere else.
- **Approvals.** Sub-agents can never ask you anything: under Hermes's default `smart` mode they (and cron jobs)
  refuse risky commands. The kit now sets `approvals.mode` from `APPROVAL_MODE` (default `off`, the guide's design)
  instead of leaving it to the dashboard; `./setup.sh tool verify` checks it.
- **Stuck sub-agents.** `delegation.child_timeout_seconds: 1800` stops a sub-agent that makes no progress for 30
  minutes (Hermes's default never stops one).

Other things to know:

- Sub-agents use the planner's reasoning effort unless `delegation.reasoning_effort` is set; `medium` there saves
  OpenRouter spend on routine pieces.
- They cannot delegate further, ask you questions, write `MEMORY.md`, send messages or schedule jobs (Hermes blocks
  those tools for children); they do get the terminal, files and sudo.
- `max_iterations` (200 here, Hermes default 250) bounds each sub-agent's tool loop. A one-shot `hermes chat -q` run
  may spawn at most 2 sub-agents by default (`delegation.oneshot_max_children`).
- With worktree isolation each sub-agent works on its own `hermes-subagent/<id>` branch under `<repo>/.worktrees/`;
  it needs the `local` terminal backend, which both profiles use.
