#!/bin/bash
# Builds FakeBatteryDriver.kext (Intel / hackintosh only).
#
# Needs: Xcode or the Command Line Tools, plus Acidanthera's MacKernelSDK:
#   git clone https://github.com/acidanthera/MacKernelSDK
# Put the MacKernelSDK folder next to this script, or set MACKERNELSDK=/path/to/it
set -e
cd "$(dirname "$0")"

SDK="${MACKERNELSDK:-./MacKernelSDK}"
KEXT="FakeBatteryDriver.kext"

if [ ! -d "$SDK/Headers" ]; then
  echo "MacKernelSDK not found at: $SDK"
  echo "Run: git clone https://github.com/acidanthera/MacKernelSDK"
  exit 1
fi

rm -rf "$KEXT" FakeBatteryDriver.o
mkdir -p "$KEXT/Contents/MacOS"

echo "Compiling..."
clang++ -arch x86_64 -mmacosx-version-min=11.0 -std=c++17 -O2 -Wall -Wno-deprecated-declarations \
  -nostdinc -nostdinc++ -isystem "$SDK/Headers" \
  -fno-builtin -fno-exceptions -fno-rtti -fno-common -fno-stack-protector -fapple-kext -mkernel \
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
  -c FakeBatteryDriver.cpp -o FakeBatteryDriver.o

echo "Linking..."
clang++ -arch x86_64 -mmacosx-version-min=11.0 -nostdlib \
  -Xlinker -kext -Xlinker -export_dynamic \
  -L"$SDK/Library/x86_64" -lkmodc++ -lkmod -lcc_kext \
  -o "$KEXT/Contents/MacOS/FakeBatteryDriver" FakeBatteryDriver.o

cp Info.plist "$KEXT/Contents/Info.plist"
plutil -lint "$KEXT/Contents/Info.plist"
rm -f FakeBatteryDriver.o

echo
echo "Built $KEXT"
file "$KEXT/Contents/MacOS/FakeBatteryDriver"
echo "Next: copy it into EFI/OC/Kexts and add it to config.plist (see README.md)."
