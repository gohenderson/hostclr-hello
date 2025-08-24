# hostclr-hello

Native C++ host that loads a .NET **9.0** framework-dependent component and invokes an `[UnmanagedCallersOnly]` method.

This README captures the exact steps, commands, and gotchas we used to get from zero → working on Linux (Debian/Ubuntu-like).

---

## TL;DR — Build & Run with CMake

We now use **CMake** instead of shell scripts. Open the repo in CLion (or run CMake manually) and it will:

- build the managed component with `dotnet publish`
- build the native host with `g++` via CMake’s rules
- copy the resulting `host` executable next to `ManagedLibrary.dll` and `ManagedLibrary.runtimeconfig.json`
- register a **CTest** (`run_hostclr`) that you can run in CLion or with `ctest`

```bash
# One-shot manual build & run
cmake -S . -B build
cmake --build build
cd build
ctest -R run_hostclr --verbose
```

Expected output:
```
Calling the C# function...
Hello from C#!
Done.
```

---

## Project layout
```
hostclr-hello/
├─ CMakeLists.txt              # builds managed + native, sets up CTest
├─ ManagedLibrary/
│  ├─ ManagedLibrary.csproj    # net9.0, generates runtimeconfig.json
│  └─ Library.cs               # contains UnmanagedCallersOnly method
└─ NativeHost/
   └─ host.cpp                 # native host using hostfxr/nethost
```

### ManagedLibrary.csproj (key bits)
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
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

> **Important:** For `load_assembly_and_get_function_pointer`, pass the **managed method name** (`"SayHello"`) — not the lowercase `EntryPoint` string.

---

## Using CLion

When you open the repo in CLion, CMake defines several build/run configurations:

- **`managed`** → builds the .NET component (`dotnet publish`)
- **`host_native`** → compiles the C++ host into a binary
- **`All CTest`** → runs the registered test (`run_hostclr`) which executes the staged host in the correct working directory

👉 At the moment, **`managed`** and **`host_native`** are just build helpers. Use **`All CTest`** to actually run and see output.

---

## Common errors & fixes

**`rc = -2147450733`**
- *Meaning:* The runtime config wasn’t found.
- *Fix:* Run the staged `host` in the same folder as `ManagedLibrary.dll` + `ManagedLibrary.runtimeconfig.json` (CTest does this automatically).

**`rc = -2147450730`**
- *Meaning:* Framework resolution failed (runtime mismatch).
- *Fix:* Make sure you have a matching shared runtime for **net9.0** installed.

**`Initialization for self-contained components is not supported`**
- *Fix:* Always build the managed library **framework-dependent**, not self-contained.

---

## Cleaning
```bash
git clean -xdf  # removes bin/ obj/ and build artifacts (be cautious!)
```

## License
MIT (or your choice).
