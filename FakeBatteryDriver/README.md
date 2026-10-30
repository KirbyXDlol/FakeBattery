# FakeBatteryDriver.kext

A tiny kext that makes macOS believe a battery exists. It publishes an `IOPMPowerSource`
(the same kind of object real laptop batteries use). The **FakeBattery** app sets the
percentage and charging state through IOKit, so `pmset -g batt`, System Settings and the
native menu bar item can all follow it.

**Intel / hackintosh only.** Third-party kexts do not exist on Apple Silicon.
**Experimental.** It is kernel code and I could not compile or test it where I wrote it.

## Build

```
git clone https://github.com/acidanthera/MacKernelSDK
bash build_kext.sh
```

If the compile or link step fails, send me the exact error and I will fix it.

## Install (OpenCore)

1. Copy `FakeBatteryDriver.kext` to `EFI/OC/Kexts/`.
2. Add it under `Kernel -> Add` in `config.plist` (ProperTree: Cmd+Shift+R, "OC Snapshot"):
   - BundlePath: `FakeBatteryDriver.kext`
   - ExecutablePath: `Contents/MacOS/FakeBatteryDriver`
   - PlistPath: `Contents/Info.plist`
   - Arch: `x86_64`, Enabled: `true`
3. **Keep a backup of your working EFI on a USB stick first.**
4. Reboot, then open the FakeBattery app. It pushes its saved state to the driver.

Do not combine it with another battery solution (ACPI battery SSDT, ACPIBatteryManager,
SMCBatteryManager). You would get two batteries.

## Check that it works

```
ioreg -rc FakeBatteryManager     # the driver is loaded
pmset -g batt                    # macOS sees a battery
```

## Is SIP involved?

- **Injected by OpenCore (above): no SIP change is needed.** OpenCore adds the kext to the
  kernel cache at boot, before macOS applies SIP or kext approval. The kext does not need
  to be signed.
- Only if you copied the kext into `/Library/Extensions` would SIP and kext approval matter.
  Do not do that. Injection through OpenCore is the cleaner way.

## Safety notes

- The driver never sets the kernel's low-battery or critical-battery flags. It also never
  reports below a floor (default 3%, change it in the app) so macOS is less likely to react
  to a very low level by sleeping. Connecting the "power adapter" in the app avoids it entirely.
- If a boot panics or loops: in the OpenCore picker reset NVRAM, or boot from your backup EFI,
  and disable the kext entry in `config.plist`.
- The desktop SMBIOS you use may hide the battery UI. That is separate from this driver.
