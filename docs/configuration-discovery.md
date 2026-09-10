# Application configuration discovery

This document records confirmed configuration stores and initial DSC safety boundaries. Credential-like values are excluded.

| Application | Confirmed configuration store | Initial resource posture |
|---|---|---|
| NINA | `%LOCALAPPDATA%\NINA\NINA.sqlite`; versioned `user.config`; plugin manifests under `%LOCALAPPDATA%\NINA\Plugins` | Audit only until the SQLite schema or a supported management API is understood |
| ASTAP | `%LOCALAPPDATA%\astap\astap.cfg` (`key=value`) | Allow-listed Get/Test first; controlled Set can follow after round-trip tests |
| PHD2 | `HKCU\Software\StarkLabs\PHDGuidingV2`, including numbered profiles | Audit stable profile policy; keep calibration and hardware identity audit-only |
| SharpCap | `%APPDATA%\SharpCap\CaptureProfiles\*.ini` | Audit explicit named profiles; do not manage `_autosave` profiles |
| ASCOM Platform | `HKLM\SOFTWARE\ASCOM` and `HKLM\SOFTWARE\WOW6432Node\ASCOM` | Registration inventory is audit-only |
| iOptron Commander | `HKCU\Software\iOptron\iOptronCommander2017` | Audit stable connection preferences; exclude telemetry/runtime state |
| iOptron iGuider | `HKCU\Software\iOptron\iOptron iGuider` | Audit stable camera preferences; exclude runtime status |
| iOptron iPolar | `HKCU\Software\iOptron\iOptron iPolar` | Audit preferences and ASCOM driver reference; calibration remains audit-only |
| OGMAVision ASCOM | ASCOM driver registration under `HKLM\SOFTWARE\WOW6432Node\ASCOM` | Registration inventory until a separate supported settings store is confirmed |
| qfoc focuser | `HKLM\SOFTWARE\WOW6432Node\ASCOM\Focuser Drivers\ASCOM.qfoc.Focuser` | Audit first; motion, limits, and saved position are write-sensitive |
| Dark Sky Geek Switch Hub | `HKLM\SOFTWARE\WOW6432Node\ASCOM\Switch Drivers\ASCOM.DarkSkyGeek.SwitchHub` | Audit topology/mapping; changing it can affect powered equipment |

## Resource design rules

- A resource boundary follows an independently managed configuration format, usually one application or driver.
- Installation/version resources remain separate from application-setting resources.
- Resources preserve unknown settings and reject credential-like keys.
- Set is disabled until the application is known to be stopped and round-trip behavior has been tested.
- Calibration, telemetry, caches, logs, and hardware-derived state are not portable policy.
- Cross-application paths are dependencies: verify the configured value, target existence, and provider component before remediation.
