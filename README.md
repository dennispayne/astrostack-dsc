<div align="center">
  <img src="assets/astrostack-dsc.svg" width="220" alt="AstroStack DSC telescope and configuration logo">
  <h1>AstroStack DSC</h1>
  <p><strong>Keep an astrophotography workstation aligned, repeatable, and ready for clear skies.</strong></p>
  <p>
    <a href="https://github.com/dennispayne/astrostack-dsc/actions/workflows/validate.yml"><img alt="Validation" src="https://github.com/dennispayne/astrostack-dsc/actions/workflows/validate.yml/badge.svg"></a>
    <img alt="DSC v3" src="https://img.shields.io/badge/DSC-v3-6366f1?style=flat-square">
    <img alt="PowerShell 7" src="https://img.shields.io/badge/PowerShell-7-2563eb?style=flat-square">
    <img alt="Platform Windows" src="https://img.shields.io/badge/platform-Windows-0891b2?style=flat-square">
  </p>
</div>

AstroStack DSC audits and maintains the applications, datasets, drivers, plugins, and selected application settings used by an astrophotography workstation. Its pinned, modular configuration is designed to be reproducible today and composable when major stack components change later.

> [!NOTE]
> The project currently targets one real workstation and is evolving from installation/version compliance into safely tested application-level configuration.

## Structure

- `manifest/components/` contains one pinned component definition per file.
- `config/modules/` contains generated DSC configuration documents grouped into swappable modules.
- `config/astro-stack.dsc.config.json` composes those modules with `Microsoft.DSC/Include`.
- `resources/AstroComponent/` implements installation and version-state discovery/remediation.
- `resources/AstapConfig/` is the first specialized application-config resource and currently audits allow-listed ASTAP settings.
- `scripts/Generate-DscConfig.ps1` regenerates module and aggregate configuration documents.
- `scripts/Test-Compliance.ps1` prepares DSC resource discovery, regenerates the configuration, and runs the complete compliance check.

Package caches are not part of the repository. Remediation consumes wgfetch's explicit
PackageIdentifier-to-path artifact map through `ArtifactMapPath`; it never assumes a cache layout.

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

## wgfetch contract

Each component uses `schemaVersion: 1` and records both identities:

- `id` is AstroStack's stable lowercase slug.
- `wingetId` is wgfetch/local-winget's `PackageIdentifier`.

`expectedVersion` is a human-controlled compliance pin. wgfetch reports discovered releases in
`availableVersion`; it must never advance `expectedVersion`.

Field ownership is strict:

| Owner | Fields |
|---|---|
| wgfetch | `downloadUrl`, `downloadFileName`, `sha256`, `verified`, `availableVersion` |
| Human | Every other field, including `expectedVersion`, `notes`, install behavior, module, and kind |

Apply a schemaVersion 1 wgfetch export with:

```powershell
.\scripts\Merge-WgfetchPatch.ps1 -PatchPath <path-to-patch.json>
```

The merger joins on `wingetId` and copies only the five machine-owned fields, preserving investigative
notes and all policy. A non-null `downloadUrl` requires a 64-character `sha256`, and its host must be in
the component's human-owned `allowlistDomains`. `requiresAuth: true` marks acquisition boundaries such
as SharpCap's protected download flow. It is consumed by wgfetch and does not prevent DSC from using
an already acquired, mapped, checksum-matching local artifact.

For remediation, wgfetch exports this path-map shape:

```json
{
  "schemaVersion": 1,
  "artifacts": {
    "AstroStack.NINA": "installers/AstroStack.NINA/3.2.0.9001/NINASetupBundle.zip"
  }
}
```

Relative artifact paths resolve from the mapping file's directory. AstroStack verifies the component
checksum before execution. Archives such as NINA's nested-installer ZIP remain byte-for-byte wgfetch
artifacts; AstroStack does not extract or repack them, and remediation remains blocked until explicit
nested-installer handling is implemented.

## Testing strategy

DSC configuration documents are declarative inputs, so testing is layered:

- **Schema/contract tests** validate manifests, generated configuration documents, and resource JSON input/output.
- **Unit tests** exercise PowerShell functions with fixture registry/configuration data where logic can be isolated.
- **Integration tests** invoke each command-based DSC resource's Get/Test/Set contract in a controlled environment.
- **Compliance tests** run `dsc config test` against the real workstation, as `Test-Compliance.ps1` does.
- **Remediation tests** should use disposable fixtures or a test VM before running `dsc config set` against live application configuration.

Pester is appropriate for the PowerShell resource logic and generator. It does not replace DSC's own schema validation or live compliance tests.

Run the current unit tests with:

```powershell
.\scripts\Test-Repository.ps1
```

GitHub Actions runs the same machine-independent checks on Windows with a five-minute timeout and
cancels superseded runs. The workflow intentionally omits CodeQL and the workstation-specific live
compliance test.

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md) for safety and testing expectations. Use the issue forms for
bugs, feature requests, and questions. Security-sensitive reports belong in GitHub's private
vulnerability reporting flow described in [SECURITY.md](SECURITY.md).

## Managed paths

A path referenced by an application setting is treated as a dependency:

1. The owning component or dataset declares the path it provides.
2. The consuming application-config resource depends on that provider.
3. Get/Test verifies both the configured value and that the target exists and has the expected identity/version.
4. Set may create safe repository-independent directories or install known components, but it must not fabricate unknown executables or silently overwrite user data.

This allows DSC to build well-understood prerequisites while leaving destructive or poorly understood application configuration in audit-only mode until its behavior is verified.
