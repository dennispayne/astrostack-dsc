# Contributing

AstroStack DSC is a homegrown, workstation-first project. Small, testable changes are preferred over broad abstractions.

## Before changing behavior

- Open an issue for new application resources, remediation behavior, or component-schema changes.
- Confirm the application's authoritative configuration store rather than guessing.
- Separate installation/version state from application-internal settings.
- Default hardware-sensitive, credential-bearing, database-backed, calibration, and runtime state to audit-only.
- Preserve the wgfetch field-ownership contract documented in the README.

## Local validation

Run:

```powershell
.\scripts\Test-Repository.ps1
```

Run the live compliance check only on a suitably configured Windows workstation:

```powershell
.\scripts\Test-Compliance.ps1
```

`dsc config set` can install software or alter application state. Use fixtures or a disposable VM before adding or changing remediation.

For changes to DSC resource behavior, run the synthetic end-to-end harness when DSC v3 is installed:

```powershell
.\tests\e2e\Invoke-EndToEnd.ps1
```

## Pull requests

Keep pull requests focused. Explain the behavioral change, include Pester coverage for reusable logic, and note any hardware or process-safety constraints. Never commit package binaries, credentials, API keys, equipment serial numbers, or precise location data.
