# AstroStack DSC

DSC v3 configuration for auditing and maintaining the software, datasets, and NINA plugins used by this astrophotography workstation.

## Structure

- `manifest/components/` contains one pinned component definition per file.
- `config/modules/` contains generated DSC configuration documents grouped into swappable modules.
- `config/astro-stack.dsc.config.json` composes those modules with `Microsoft.DSC/Include`.
- `resources/AstroComponent/` implements installation and version-state discovery/remediation.
- `scripts/Generate-DscConfig.ps1` regenerates module and aggregate configuration documents.
- `scripts/Test-Compliance.ps1` prepares DSC resource discovery, regenerates the configuration, and runs the complete compliance check.

Package caches are not part of the repository. A caller-supplied `DownloadsRoot` is required for remediation.

## Compliance check

Run from an elevated PowerShell 7 session:

```powershell
.\scripts\Test-Compliance.ps1
```

The script prints one row per component and returns a nonzero exit code if DSC reports errors or drift. The raw JSON result is written to the system temporary directory unless `-OutputPath` is specified.

The aggregate check currently takes several minutes because every `Microsoft.DSC/Include` invocation starts a nested DSC process and performs resource discovery. Individual module documents under `config/modules/` can be tested directly during development.

## Current scope

`AstroStack/Component` currently manages:

- installed application versions from Windows uninstall registry entries;
- ASTAP executable and star-database presence/version state;
- the pinned NINA plugin set based on NINA's latest load log;
- installer and dataset remediation when a verified URL, checksum, and silent install command are available.

Application-internal settings are not yet managed. Those will use specialized resources for each independently managed configuration format, with explicit dependencies on required applications, datasets, and paths.

## Testing strategy

DSC configuration documents are declarative inputs, so testing is layered:

- **Schema/contract tests** validate manifests, generated configuration documents, and resource JSON input/output.
- **Unit tests** exercise PowerShell functions with fixture registry/configuration data where logic can be isolated.
- **Integration tests** invoke each command-based DSC resource's Get/Test/Set contract in a controlled environment.
- **Compliance tests** run `dsc config test` against the real workstation, as `Test-Compliance.ps1` does.
- **Remediation tests** should use disposable fixtures or a test VM before running `dsc config set` against live application configuration.

Pester is appropriate for the PowerShell resource logic and generator. It does not replace DSC's own schema validation or live compliance tests.

## Managed paths

A path referenced by an application setting is treated as a dependency:

1. The owning component or dataset declares the path it provides.
2. The consuming application-config resource depends on that provider.
3. Get/Test verifies both the configured value and that the target exists and has the expected identity/version.
4. Set may create safe repository-independent directories or install known components, but it must not fabricate unknown executables or silently overwrite user data.

This allows DSC to build well-understood prerequisites while leaving destructive or poorly understood application configuration in audit-only mode until its behavior is verified.
