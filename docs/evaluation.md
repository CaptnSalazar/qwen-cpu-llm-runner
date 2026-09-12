# Evaluation notes

This project includes a deliberately small smoke evaluation. It is intended to validate that the local server produces direct answers and to make latency regressions visible; it is not a benchmark of general model capability.

## Reproduce

Start a fresh direct-answer server. `-NoReasoning` is essential for this particular short-output suite.

```powershell
.\run.ps1 -Mode server -NoReasoning
```

In a second PowerShell window, run:

```powershell
.\scripts\smoke-eval.ps1
```

The test sends three serial, 8-token-max requests: arithmetic, a geography fact, and a simple number sequence. It uses streaming so it can report time to the first visible token and total response time. The prompts contain `/no_think`, and the server is configured with `--reasoning off`.

Run it three times after a warm start and report median time-to-first-token and total latency if you publish a performance comparison. Do not compare results across different quantizations, contexts, thread counts, or GPU backends without listing those settings.

## Recorded CPU baseline (2026-09-12)

| Field | Recorded value |
| --- | --- |
| Operating system | Windows 10 Home Single Language, build family `10.0.26200` |
| Processor information available to runner | 32 logical CPUs |
| Runtime | llama.cpp `b10930`, Windows x64 CPU build |
| Model | Qwen3-32B Q6_K GGUF, 26.9 GB |
| Backend | CPU-only |
| Server context | 16,384 tokens |
| Server threads | 31 |
| GPU offload | Requested `999` layers, unavailable on CPU build |

### Initial result: configuration validation, not an accuracy result

The first collected run started the server in its previous **auto-reasoning** configuration, then imposed a four-token output cap. All three requests completed but emitted no visible final-answer tokens because the token budget was consumed by hidden reasoning. The measured totals were:

| Case | Total latency | Visible output | Correctness |
| --- | ---: | --- | --- |
| Arithmetic | 73,559 ms | Empty | Not scored |
| Geography | 67,796 ms | Empty | Not scored |
| Pattern | 73,694 ms | Empty | Not scored |
| Mean | 71,683 ms | — | Not applicable |

This result must **not** be interpreted as 0/3 model accuracy. It demonstrates why direct-answer evaluation needs both `/no_think` in the prompt and `-NoReasoning` at server startup. The current `smoke-eval.ps1` uses an eight-token cap and is intended to be run only after the server has been restarted using the command above.

## Reporting template

```text
OS:
CPU / logical CPUs:
RAM:
GPU and VRAM (or CPU-only):
llama.cpp build:
Model and quantization:
Context size:
Thread count:
GPU layers:
Reasoning mode:
Warm-up used: yes/no
Median first visible token latency:
Median total latency:
Pass count:
```
