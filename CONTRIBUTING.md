# Contributing

Thanks for contributing.

## Development checks

Run these checks before opening a pull request:

```powershell
$files = @('run.ps1', 'scripts/install-llama-cpp.ps1', 'scripts/smoke-eval.ps1')
foreach ($file in $files) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors)
  if ($errors.Count) { $errors | ForEach-Object Message; exit 1 }
}
Get-Content .\config\models.json -Raw | ConvertFrom-Json | Out-Null
```

Do not commit `models/`, `runtime/`, partial downloads, model weights, tokens, or local evaluation output. Keep the default listener on loopback. New model presets need an upstream URL, a verified SHA-256 digest, realistic memory guidance, and clear licensing.

## Pull requests

- Keep each pull request focused.
- Explain the user-visible behavior change.
- Add or update docs for flags, presets, and evaluation changes.
- Include reproducible measurements for performance claims.
