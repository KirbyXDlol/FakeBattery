# FakeBattery

A fake battery for Macs that don't have one, made of two parts that work together:

| Part | What it does | Runs on |
| --- | --- | --- |
| **FakeBattery** (menu bar app) | A battery icon and a menu styled after the macOS Tahoe battery menu, with a fully customizable percentage, charging state and drain/charge simulation. | Apple Silicon and Intel, macOS 13+ |
| **FakeBatteryDriver** (kext) | Makes macOS itself believe a battery exists, so `pmset`, System Settings and the native menu bar item follow it. The app controls it. | **Intel hackintosh only** (OpenCore) |

You can use the app alone (it just draws an icon), or add the driver for a "real" system battery.

> **Status:** the app is stable for everyday use. The driver is **experimental** kernel code:
> keep a backup of your working EFI before trying it, and please open an issue if something breaks.

> **Disclaimer:** unofficial and unaffiliated with Apple. Hackintosh use is at your own risk.

## Repository layout

```
.
├── README.md
├── FakeBattery/              # menu bar app (Swift)
│   ├── main.swift
│   └── build.sh
└── FakeBatteryDriver/        # kext (C++), Intel hackintosh only
    ├── FakeBatteryDriver.cpp
    ├── Info.plist
    ├── build_kext.sh
    └── README.md
```

## Part 1: the menu bar app

### Features

- Real `NSStatusItem`, so it sits in the native menu bar. **⌘-drag** it next to the system icons.
- Menu modeled on the system one: **Battery** header with percentage, **Power Source**,
  **Energy Mode** (Automatic / Low Power / High Power), "No Apps Using Significant Energy"
  and **Battery Settings…**
- Icon behaves like the real one: green while charging (with a bolt), yellow in Low Power mode,
  red at 20% or less.
- **Battery Settings…** window:
  - charge level (slider and exact value)
  - charging (power adapter) on/off, show/hide the percentage text
  - **simulate drain / charge**: lose 1% every *X* minutes (default 10) and gain 1% every *Y* minutes
    while charging (default 5). Values from 0.1 to 1000 minutes
  - fake **low battery warnings** at 10%, 5% and 1% (a pop-up only, nothing is ever shut down),
    which can be switched off
  - driver status, option to hide the app's own icon, safety floor for the driver
  - launch at login and quit
- Settings are remembered between launches.
- Launching the app again opens Battery Settings, which helps if you hid the icon.

### Build from source

Requirements: macOS 13 or newer and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/<your-username>/FakeBattery.git
cd FakeBattery/FakeBattery
bash build.sh
open FakeBattery.app
```

`build.sh` produces a **universal** `FakeBattery.app` (Apple Silicon and Intel), signs it ad hoc and
also writes `FakeBattery.zip`. If the universal build fails, it falls back to a build for your own Mac.

### Running on another Mac

The app is ad-hoc signed, not notarized, so Gatekeeper blocks it the first time. Either:

```bash
xattr -dr com.apple.quarantine FakeBattery.app
```

or open it once and allow it in **System Settings → Privacy & Security → Open Anyway**.
Building from source on that Mac avoids the problem.

On a laptop, hide the real battery icon (System Settings → Control Center → Battery) or you will
see two.

## Part 2: the driver (Intel hackintosh only)

`FakeBatteryDriver.kext` publishes an `IOPMPowerSource`, the object type real laptop batteries use.
The app feeds it the percentage and charging state through IOKit. Third-party kexts don't exist on
Apple Silicon, so this part is for hackintoshes only.

### Build from source

Requirements: Xcode or the Command Line Tools, and
[Acidanthera's MacKernelSDK](https://github.com/acidanthera/MacKernelSDK).

**MacKernelSDK is not included in this repository.** It is a large, separate project with its own
license, so you need to download it yourself and put it in the `FakeBatteryDriver` folder.
Either way, the folder must end up named `MacKernelSDK`:

- **With git:**
  ```bash
  cd FakeBattery/FakeBatteryDriver
  git clone https://github.com/acidanthera/MacKernelSDK
  ```
- **Without git:** open the [MacKernelSDK page](https://github.com/acidanthera/MacKernelSDK),
  choose **Code → Download ZIP**, unzip it, rename the folder to `MacKernelSDK` (remove any
  `-master` suffix) and move it into `FakeBatteryDriver`.

Then build:

```bash
cd FakeBattery/FakeBatteryDriver
bash build_kext.sh
```

This produces `FakeBatteryDriver.kext`. To keep the SDK somewhere else, set
`MACKERNELSDK=/path/to/MacKernelSDK` when running the script.

### Install with OpenCore

1. **Back up your working EFI** (for example on a USB stick).
2. Copy `FakeBatteryDriver.kext` to `EFI/OC/Kexts/`.
3. In `config.plist`, add it under `Kernel → Add` (ProperTree: Cmd+Shift+R, "OC Snapshot"):

   | Key | Value |
   | --- | --- |
   | BundlePath | `FakeBatteryDriver.kext` |
   | ExecutablePath | `Contents/MacOS/FakeBatteryDriver` |
   | PlistPath | `Contents/Info.plist` |
   | Arch | `x86_64` |
   | Enabled | `true` |

4. Reboot, then start the FakeBattery app. It pushes its saved state to the driver.

Check that it works:

```bash
ioreg -rc FakeBatteryManager   # the driver is loaded
pmset -g batt                  # macOS sees a battery
```

In Battery Settings… the driver line should read "connected". You can then untick
"Show FakeBattery icon in menu bar" and let the native item take over.

### Does it need SIP disabled?

No, as far as I know. OpenCore injects the kext into the kernel cache at boot, before macOS applies
SIP or kext approval, and the kext doesn't need to be signed. SIP only matters if you install the kext
into `/Library/Extensions`, which is not recommended.

### Safety

- The driver never raises macOS's low-battery or critical-battery flags.
- It never reports below a **floor** (default 3%, adjustable in the app, 0 disables it), so macOS is
  less likely to react to a very low level by sleeping. Connecting the "power adapter" avoids it entirely.
- Don't combine it with another battery solution (ACPI battery SSDT, ACPIBatteryManager,
  SMCBatteryManager), or you will get two batteries.
- If a boot panics or loops: reset NVRAM in the OpenCore picker or boot your backup EFI, then disable
  the kext entry in `config.plist`.
- A desktop SMBIOS may hide the battery UI regardless of the driver.

## How the two parts talk

The app calls `IORegistryEntrySetCFProperties` on the `FakeBatteryManager` service. The driver accepts:

| Property | Type | Meaning |
| --- | --- | --- |
| `FBPercent` | number | charge, 0 to 100 |
| `FBCharging` | boolean | power adapter connected / charging |
| `FBTimeRemaining` | number | minutes, or `65535` for "no estimate" |
| `FBFloor` | number | lowest percentage ever shown to macOS (0 to 50) |

State persists in the app, not in the kext, so the driver starts at 80% after every boot until the
app sends its saved value.

## Troubleshooting

| Problem | Try |
| --- | --- |
| `./build.sh: permission denied` | `bash build.sh` |
| Build errors after updating | make sure you replaced **all** files from the same version |
| App blocked on another Mac | see "Running on another Mac" |
| Icon missing | System Settings → Menu Bar, then ⌘-drag it into place |
| Driver "not found" in settings | check `ioreg -rc FakeBatteryManager` and the `config.plist` entry |
| Kext build fails | open an issue with the full compiler output and your Xcode version |

## License

This project is released under the [MIT License](LICENSE).

MacKernelSDK is **not** part of this project and is not covered by this license. It is a separate
project by Acidanthera, distributed under its own license, which you download yourself to build the driver.
