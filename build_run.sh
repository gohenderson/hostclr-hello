#!/usr/bin/env bash
set -euo pipefail

have_dotnet9() {
  command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | awk '{print $1}' | grep -q '^9\.'
}

# 0) Prereqs
if ! have_dotnet9; then
  echo "[.NET] 9.x SDK not found; installing..."
  wget https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
  sudo dpkg -i packages-microsoft-prod.deb
  rm -f packages-microsoft-prod.deb
  sudo apt update
  sudo apt install -y dotnet-sdk-9.0
else
  echo "[.NET] 9.x SDK already present; skipping installation."
fi

# Ensure native build deps (install regardless)
sudo apt install -y g++ build-essential

# 1) Build the managed component (framework-dependent, emits runtimeconfig)
cd ManagedLibrary
dotnet build -c Release
cd ..

# 2) Build the native host (auto-finds headers/libs)
cd NativeHost
chmod +x build_host.sh
./build_host.sh

# 3) Run: place host next to managed DLL + runtimeconfig
cp host ../ManagedLibrary/bin/Release/net9.0/
cd ../ManagedLibrary/bin/Release/net9.0/
./host
# Expect:
# Calling the C# function...
# Hello from C#!
# Done.