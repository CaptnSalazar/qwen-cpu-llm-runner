# Qwen CPU LLM Runner

A Windows-first, open-source launcher for running Qwen GGUF language models locally with [llama.cpp](https://github.com/ggml-org/llama.cpp). It installs a portable runtime, downloads verified weights, launches an OpenAI-compatible API, and includes a small reproducible latency smoke test.

**Privacy-first:** the model and inference server run on your PC. The installer and downloader access upstream releases only to fetch the runtime and model you choose.

## Highlights

- Accuracy-first default: official Qwen3-32B Q6_K GGUF (26.9 GB).
- CPU-only, CUDA, and Vulkan runtime installation.
- Local OpenAI-compatible endpoint at `127.0.0.1:8080`.
- SHA-256 model validation after download.
- Direct-answer (`--reasoning off`) mode for low-overhead tasks.
- Reproducible streaming latency and correctness smoke evaluation.

## Requirements

- Windows 10/11 x64 and Windows PowerShell 5.1+ or PowerShell 7.
- At least **32 GB free RAM** for the Q6 preset; 48 GB+ is more comfortable with a 16K context. Use Q4 on tighter systems.
- Roughly 30 GB of free disk for Q6, or 22 GB for Q4, plus runtime overhead.
- Internet access only during installation/model download.

## Quick start

Run these from the repository root in PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install-llama-cpp.ps1 -Backend cpu
.\run.ps1 -Mode download -Model qwen3-32b-q6
.\run.ps1
```

The first model load is intentionally slow on CPU: it maps a 26.9 GB model and creates its context cache.

### Choose a runtime backend

```powershell
# CPU-only: works everywhere on x64 Windows
.\scripts\install-llama-cpp.ps1 -Backend cpu

# NVIDIA GPU with a compatible CUDA driver
.\scripts\install-llama-cpp.ps1 -Backend cuda

# Broad GPU support where Vulkan is available
.\scripts\install-llama-cpp.ps1 -Backend vulkan
```

Use `-GpuLayers 0` or `-NoGpu` to force CPU inference. With an accelerator build, the runner tries to offload all layers; set `-GpuLayers N` to stay within VRAM.

## Run modes

Interactive chat:

```powershell
.\run.ps1
```

Single prompt:

```powershell
.\run.ps1 -Prompt "Explain database index trade-offs in three bullets."
```

OpenAI-compatible local server:

```powershell
.\run.ps1 -Mode server -Port 8080
```

The API is available at `http://127.0.0.1:8080/v1/chat/completions`. It binds to loopback by default. Do not use `-ListenAddress 0.0.0.0` unless you provide authentication and network controls separately.

### Direct-answer mode (no reasoning)

For short, straightforward responses without reasoning tokens, stop the current server with `Ctrl+C` and start a new one:

```powershell
.\run.ps1 -Mode server -NoReasoning
```

`-NoReasoning` applies when the server starts; it cannot change an already-running process.

## Models and tuning

| Preset | Weights | Intended use | Default context |
| --- | ---: | --- | ---: |
| `qwen3-32b-q6` | 26.9 GB | Best shipped quality / CPU latency is acceptable | 16,384 |
| `qwen3-32b-q4` | 19.8 GB | Lower-memory fallback | 8,192 |

The shipped model files come from Qwen's Apache-2.0 GGUF repository. Their expected SHA-256 digests are in [config/models.json](config/models.json) and are checked at download completion. Recheck an existing model with:

```powershell
.\run.ps1 -VerifyModel
```

Useful overrides:

```powershell
# Reduce CPU contention and extend context when you have enough memory
.\run.ps1 -Threads 12 -ContextSize 32768

# Use the smaller preset
.\run.ps1 -Model qwen3-32b-q4

# Validate the installation and detected runtime
.\run.ps1 -Mode doctor
```

## Evaluation

With a no-reasoning server already running, execute:

```powershell
.\scripts\smoke-eval.ps1
```

The evaluator warms the model, sends three short direct-answer prompts with `temperature: 0`, streams responses, and reports first visible token time, total time, output, and exact-match correctness. See [docs/evaluation.md](docs/evaluation.md) for methodology and the recorded baseline.

### Measured CPU latency baseline

The following is the first measured local baseline for this project. It used the Qwen3-32B Q6_K model (26.9 GB) with the CPU-only llama.cpp `b10930` build, 31 threads, and a 16,384-token context on Windows 10 with 32 logical CPUs.

| Direct-answer case | Total API completion latency |
| --- | ---: |
| Arithmetic | 73.56 s |
| Geography | 67.80 s |
| Number pattern | 73.69 s |
| **Mean** | **71.68 s** |

This is a conservative CPU-only reference, not a quality score: the server for that first run was still configured for automatic reasoning while each request was capped at four output tokens. It therefore emitted no visible final answer, and those three cases are **not scored for correctness**. Restart with `-NoReasoning` and use the included evaluator to produce a valid direct-answer result for your hardware. Keep model, quantization, context size, thread count, and backend in every published comparison.

### Performance defaults

The launcher uses all but one logical CPU by default, assigns the same count to prompt/batch processing, and lets llama.cpp automatically select Flash Attention when supported. It keeps the accuracy-first Q6 quantization and 16K context; both materially increase memory use and CPU latency. For faster local responses, use the Q4 preset and a smaller context:

```powershell
.\run.ps1 -Mode server -Model qwen3-32b-q4 -ContextSize 4096 -NoReasoning
```

## Project layout

```text
config/models.json                Shipped model presets and hashes
run.ps1                           Chat, server, download, and diagnostic launcher
scripts/install-llama-cpp.ps1     Portable llama.cpp installer
scripts/smoke-eval.ps1            Local direct-answer latency smoke evaluation
docs/evaluation.md                Methodology and measured baseline
.github/workflows/validate.yml    GitHub Actions syntax/configuration validation
```

## Contributing and security

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request and [SECURITY.md](SECURITY.md) before reporting a security issue. The launcher code is MIT licensed; llama.cpp and model weights are separate projects with their own licenses. Do not redistribute model weights without complying with their license.
