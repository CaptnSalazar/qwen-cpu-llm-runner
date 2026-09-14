# Performance reports

This page records reproducible local measurements for the shipped presets. Results are hardware-specific: always report the model, quantization, context size, thread count, backend, and whether the model was warmed up.

## Quick expectations

| Preset | Model file | Memory before context and OS overhead | Free disk for download | Default context |
| --- | ---: | ---: | ---: | ---: |
| `qwen3-32b-q4` | 19.8 GB | Roughly 22 GB; 28 GB recommended | Roughly 22 GB | 8,192 |
| `qwen3-32b-q6` | 26.9 GB | Roughly 30 GB; 40 GB recommended | Roughly 30 GB | 16,384 |

These are planning numbers, not guarantees. Larger contexts, GPU offload, background applications, and Windows memory pressure can increase the requirement. A machine may technically load a preset while still being too constrained for comfortable use.

## Recorded report: CPU baseline

**Date:** 2026-09-12  
**Purpose:** initial latency reference, not a model-quality benchmark

| Field | Value |
| --- | --- |
| Operating system | Windows 10 Home Single Language, build family `10.0.26200` |
| CPU | 32 logical CPUs reported to the runner |
| RAM | Not recorded in the original run |
| GPU | CPU-only; no usable GPU offload |
| Runtime | llama.cpp `b10930`, Windows x64 CPU build |
| Model | Qwen3-32B Q6_K GGUF, 26.9 GB |
| Context size | 16,384 tokens |
| Server threads | 31 |
| GPU layers | Requested `999`; unavailable on CPU build |
| Warm-up | Not recorded in the original run |

| Case | Total completion latency | Visible output | Correctness |
| --- | ---: | --- | --- |
| Arithmetic | 73.56 s | Empty | Not scored |
| Geography | 67.80 s | Empty | Not scored |
| Number pattern | 73.69 s | Empty | Not scored |
| **Mean** | **71.68 s** | — | Not applicable |

The original server used automatic reasoning while each request was capped at four output tokens, so the token budget was consumed before a visible answer appeared. This report is retained as a configuration diagnostic, not as an accuracy score or a representative direct-answer benchmark.

## Reproduce a valid report

Start a fresh direct-answer server, then run the evaluator from a second PowerShell window:

```powershell
.\run.ps1 -Mode server -Model qwen3-32b-q4 -NoReasoning
.\scripts\smoke-eval.ps1
```

Run the evaluator three times after warm-up and report the median first-visible-token and total latency. The evaluator writes timestamped JSON reports to `benchmarks/`, which are intentionally ignored by Git. Do not compare results across different presets or backends without listing all settings.

## Report template

```text
Date:
Operating system:
CPU / logical CPUs:
RAM:
GPU / VRAM or CPU-only:
llama.cpp build:
Model and quantization:
Context size:
Server threads:
GPU layers:
Reasoning mode:
Warm-up used: yes/no
Median first visible token latency:
Median total latency:
Pass count:
```