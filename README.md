# hostclr-hello

Native C++ host that loads a .NET **9.0** framework-dependent component and invokes an `[UnmanagedCallersOnly]` method.

This README captures the exact steps, commands, and gotchas we used to get from zero → working on Linux (Debian/Ubuntu-like).

---

## TL;DR — One‑shot setup & run (build_run.sh)
```bash
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
```

> The `build_host.sh` script is included in `NativeHost/` (see below). It discovers the header & lib paths for your local .NET installation.

---

## Project layout
```
hostclr-hello/
├─ ManagedLibrary/
│  ├─ ManagedLibrary.csproj      # net9.0, generates runtimeconfig.json
│  └─ Library.cs                 # contains UnmanagedCallersOnly method
└─ NativeHost/
   ├─ host.cpp                   # native host using hostfxr/nethost
   └─ build_host.sh              # convenience build script for host
```

### ManagedLibrary.csproj (key bits)
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <GenerateRuntimeConfigurationFiles>true</GenerateRuntimeConfigurationFiles>
  </PropertyGroup>
</Project>
```

### Library.cs (example)
```csharp
using System.Runtime.InteropServices;

namespace ManagedLibrary;
public class Library
{
    [UnmanagedCallersOnly(EntryPoint = "say_hello")]
    public static void SayHello()
    {
        System.Console.WriteLine("Hello from C#!");
    }
}
```

> **Important:** For `load_assembly_and_get_function_pointer`, you pass the **managed method name** (e.g., `"SayHello"`) — not the `EntryPoint` string.

---

## Building the managed component
Framework‑dependent is required for the **component hosting** path.

```bash
cd ManagedLibrary
# Build (framework-dependent)
dotnet build -c Release
# Outputs under bin/Release/net9.0/
```

You should end up with these side-by-side:
```
ManagedLibrary.dll
ManagedLibrary.runtimeconfig.json
```

---

## Building the native host
The host uses the .NET hosting API (`nethost.h`, `hostfxr.h`, `coreclr_delegates.h`). On many distro installs, headers and `libnethost.so` live under:
```
/usr/share/dotnet/packs/Microsoft.NETCore.App.Host.linux-x64/<ver>/runtimes/linux-x64/native
```
…and `libhostfxr.so` lives under:
```
/usr/share/dotnet/host/fxr/<ver>
```

### Option A — Use the helper script
`NativeHost/build_host.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

DOTNET_ROOT="${DOTNET_ROOT:-/usr/share/dotnet}"

HOSTFXR_LIB_DIR="$(dirname "$(find "$DOTNET_ROOT" -name libhostfxr.so -print -quit)")"
INC_DIR="$(dirname "$(find "$DOTNET_ROOT/packs" -path "*/Microsoft.NETCore.App.Host.linux-x64/*/runtimes/linux-x64/native/nethost.h" -print -quit)")"
[ -z "${INC_DIR:-}" ] && { echo "Could not locate hosting headers under $DOTNET_ROOT/packs"; exit 1; }
NETHOST_LIB_DIR="$INC_DIR"

echo "HOSTFXR_LIB_DIR=$HOSTFXR_LIB_DIR"
echo "INC_DIR=$INC_DIR"
echo "NETHOST_LIB_DIR=$NETHOST_LIB_DIR"

g++ -o host host.cpp   -I"$INC_DIR"   -L"$HOSTFXR_LIB_DIR" -L"$NETHOST_LIB_DIR"   -Wl,-rpath,"$HOSTFXR_LIB_DIR:$NETHOST_LIB_DIR"   -ldl -lhostfxr -lnethost

echo "Built ./host"
```

Run it:
```bash
cd NativeHost
chmod +x build_host.sh
./build_host.sh
```

### Option B — Manual compile
```bash
# Find hostfxr and headers
export DOTNET_ROOT=/usr/share/dotnet
HOSTFXR_LIB_DIR="$(dirname "$(find "$DOTNET_ROOT" -name libhostfxr.so -print -quit)")"
INC_DIR="$(dirname "$(find "$DOTNET_ROOT/packs" -path "*/Microsoft.NETCore.App.Host.linux-x64/*/runtimes/linux-x64/native/nethost.h" -print -quit)")"
NETHOST_LIB_DIR="$INC_DIR"

# Compile
g++ -o host host.cpp   -I"$INC_DIR"   -L"$HOSTFXR_LIB_DIR" -L"$NETHOST_LIB_DIR"   -Wl,-rpath,"$HOSTFXR_LIB_DIR:$NETHOST_LIB_DIR"   -ldl -lhostfxr -lnethost
```

> **Headers to include in `host.cpp`:** `#include <nethost.h>`, `#include <hostfxr.h>`, `#include <coreclr_delegates.h>`, plus the POSIX bits `#include <dlfcn.h>`, `#include <limits.h>`, `#include <unistd.h>`, `#include <libgen.h>`.

> **Use the same handle** from `dlopen(hostfxr_path, RTLD_LAZY | RTLD_GLOBAL)` for all `dlsym` calls (`hostfxr_initialize_for_runtime_config`, `hostfxr_get_runtime_delegate`, `hostfxr_close`).

---

## Running
Place the native `host` **in the same folder** as `ManagedLibrary.dll` **and** `ManagedLibrary.runtimeconfig.json`:

```bash
cp NativeHost/host ManagedLibrary/bin/Release/net9.0/
cd ManagedLibrary/bin/Release/net9.0/
./host
```
Expected output:
```
Calling the C# function...
Hello from C#!
Done.
```

---

## Common errors & fixes

**`rc = -2147450733`**  
- *Meaning:* The runtime config wasn’t found **or** you tried to initialize a **self-contained** component (not supported for component hosting).  
- *Fix:* Ensure `ManagedLibrary.runtimeconfig.json` sits next to the DLL **and** build **framework-dependent** (no `--self-contained` for the component path).

**`rc = -2147450730`**  
- *Meaning:* Framework resolution failed (runtime version mismatch / missing shared runtime).  
- *Fix:* Ensure the runtimeconfig `tfm` matches your installed shared runtime (here: **net9.0**). Don’t use a net8 runtimeconfig on a net9-only machine. Framework-dependent is required for components.

**`rc = -2146233069`**  
- *Meaning:* `MissingMethodException`.  
- *Fix:* When calling `load_assembly_and_get_function_pointer`, pass the **managed method name** (e.g., `"SayHello"`), not the `EntryPoint` string (`"say_hello"`).

**Compile errors about `dlopen`, `dlsym`, `RTLD_LAZY`, `PATH_MAX`**  
- *Fix:* Add POSIX headers: `#include <dlfcn.h>`, `#include <limits.h>`, `#include <unistd.h>`.

**`Initialization for self-contained components is not supported`**  
- *Fix:* Don’t publish the component self-contained if you’re using `hostfxr_initialize_for_runtime_config` + `hdt_load_assembly_and_get_function_pointer`.

---

## Notes & tips
- Component hosting path requires **framework-dependent** managed bits. If you truly need single-folder portability, consider a different activation path (app activation) or install the shared runtime on target machines.
- To prefer a local `libhostfxr.so`, pass the runtimeconfig path to `get_hostfxr_path` via `get_hostfxr_parameters` and then `dlopen` that resolved path.
- On many distros the hosting headers (`nethost.h`, `hostfxr.h`, `coreclr_delegates.h`) are under the apphost pack’s `runtimes/linux-x64/native` folder; some installs use an `include/` layout. The build script auto-detects either.

---

## Cleaning
```bash
git clean -xdf  # removes bin/ obj/ etc. (be cautious!)
```

## License
MIT (or your choice).
