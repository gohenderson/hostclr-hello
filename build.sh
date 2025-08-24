# ===== 0) Prereqs ============================================================
set -euo pipefail

# Install .NET 9 SDK + C++ tools (skip if already installed)
sudo apt update
sudo apt install -y dotnet-sdk-9.0 g++ build-essential

# Base .NET location (default for distro installs)
export DOTNET_ROOT=/usr/share/dotnet

# Work in a clean folder
mkdir -p ~/hostclr-hello && cd ~/hostclr-hello

# ===== 1) Managed library (net9.0) ==========================================
mkdir -p ManagedLibrary && cd ManagedLibrary

# Create csproj (framework-dependent; emits runtimeconfig.json)
cat > ManagedLibrary.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <GenerateRuntimeConfigurationFiles>true</GenerateRuntimeConfigurationFiles>
  </PropertyGroup>
</Project>
EOF

# Create the managed code with an UnmanagedCallersOnly entrypoint
cat > Library.cs <<'EOF'
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
EOF

# Build (framework-dependent)
dotnet build -c Release

# ===== 2) Native host (C++) ==================================================
cd ..
mkdir -p NativeHost && cd NativeHost

# Create host.cpp (loads hostfxr, gets delegate, calls managed method)
cat > host.cpp <<'EOF'
#include <iostream>
#include <string>
#include <dlfcn.h>
#include <limits.h>
#include <unistd.h>
#include <libgen.h>

#include <nethost.h>
#include <hostfxr.h>
#include <coreclr_delegates.h>

struct hostfxr_exports {
    hostfxr_initialize_for_runtime_config_fn initialize = nullptr;
    hostfxr_get_runtime_delegate_fn           get_delegate = nullptr;
    hostfxr_close_fn                          close = nullptr;
    void*                                     lib_handle = nullptr;
};

static bool load_hostfxr_exports(hostfxr_exports& out, const std::string& runtimeconfig_path) {
    char hostfxr_path[1024];
    size_t size = sizeof(hostfxr_path);

    get_hostfxr_parameters params{};
    params.size = sizeof(params);
    // Point at the runtimeconfig so resolution prefers the local hostfxr if present
    params.assembly_path = runtimeconfig_path.c_str();

    int rc = get_hostfxr_path(hostfxr_path, &size, &params);
    if (rc != 0) {
        std::cerr << "get_hostfxr_path failed, rc=" << rc << "\n";
        return false;
    }

    void* lib = dlopen(hostfxr_path, RTLD_LAZY | RTLD_GLOBAL);
    if (!lib) {
        std::cerr << "dlopen(" << hostfxr_path << ") failed: " << dlerror() << "\n";
        return false;
    }

    out.initialize = (hostfxr_initialize_for_runtime_config_fn)
        dlsym(lib, "hostfxr_initialize_for_runtime_config");
    out.get_delegate = (hostfxr_get_runtime_delegate_fn)
        dlsym(lib, "hostfxr_get_runtime_delegate");
    out.close = (hostfxr_close_fn)
        dlsym(lib, "hostfxr_close");

    if (!out.initialize || !out.get_delegate || !out.close) {
        std::cerr << "Failed to resolve hostfxr exports\n";
        dlclose(lib);
        return false;
    }

    out.lib_handle = lib;
    return true;
}

int main() {
    // Find this executable's directory
    char exe_path[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path));
    if (len <= 0 || len >= (ssize_t)sizeof(exe_path)) {
        std::cerr << "Failed to get /proc/self/exe\n";
        return 1;
    }
    exe_path[len] = '\0';
    std::string exe_dir = dirname(exe_path);

    // Managed assembly + runtimeconfig expected to be beside host
    std::string assembly_path       = exe_dir + "/ManagedLibrary.dll";
    std::string runtimeconfig_path  = exe_dir + "/ManagedLibrary.runtimeconfig.json";

    hostfxr_exports fxr{};
    if (!load_hostfxr_exports(fxr, runtimeconfig_path)) return 1;

    hostfxr_handle cxt = nullptr;
    int rc = fxr.initialize(runtimeconfig_path.c_str(), nullptr, &cxt);
    if (rc != 0 || cxt == nullptr) {
        std::cerr << "hostfxr_initialize_for_runtime_config failed, rc=" << rc << "\n";
        return 1;
    }

    load_assembly_and_get_function_pointer_fn load_asm_and_get_ptr = nullptr;
    rc = fxr.get_delegate(cxt, hdt_load_assembly_and_get_function_pointer,
                          (void**)&load_asm_and_get_ptr);
    if (rc != 0 || load_asm_and_get_ptr == nullptr) {
        std::cerr << "hostfxr_get_runtime_delegate failed, rc=" << rc << "\n";
        fxr.close(cxt);
        return 1;
    }

    using say_hello_fn = void (CORECLR_DELEGATE_CALLTYPE*)();
    say_hello_fn say_hello = nullptr;

    // IMPORTANT: use managed method name "SayHello" (not the EntryPoint)
    rc = load_asm_and_get_ptr(
        assembly_path.c_str(),
        "ManagedLibrary.Library, ManagedLibrary",
        "SayHello",
        UNMANAGEDCALLERSONLY_METHOD,
        nullptr,
        (void**)&say_hello);

    if (rc != 0 || say_hello == nullptr) {
        std::cerr << "load_assembly_and_get_function_pointer failed, rc=" << rc << "\n";
        fxr.close(cxt);
        return 1;
    }

    std::cout << "Calling the C# function...\n";
    say_hello();
    fxr.close(cxt);
    std::cout << "Done.\n";
    return 0;
}
EOF

# ===== 3) Compile native host =================================================
# Discover hostfxr version directory (e.g., /usr/share/dotnet/host/fxr/9.0.x)
HOSTFXR_LIB_DIR="$(dirname "$(find "$DOTNET_ROOT" -name libhostfxr.so -print -quit)")"

# Headers/libs are typically here on distro installs:
#   /usr/share/dotnet/packs/Microsoft.NETCore.App.Host.linux-x64/<ver>/runtimes/linux-x64/native
INC_DIR="$(dirname "$(find "$DOTNET_ROOT/packs" -path "*/Microsoft.NETCore.App.Host.linux-x64/*/runtimes/linux-x64/native/nethost.h" -print -quit)")"

# Fallback if layout differs (try include/hostfxr.h and include/nethost/nethost.h)
if [ -z "$INC_DIR" ]; then
  INC_BASE="$(dirname "$(find "$DOTNET_ROOT/packs" -type f -name hostfxr.h -print -quit)")"
  NETHDR="$(dirname "$(find "$DOTNET_ROOT/packs" -type f -name nethost.h -print -quit)")"
  [ -n "$INC_BASE" ] && [ -n "$NETHDR" ] && INC_DIRS="-I$INC_BASE -I$NETHDR"
else
  INC_DIRS="-I$INC_DIR"
fi

# The nethost lib usually lives with the headers in the native folder
if [ -n "${INC_DIR:-}" ]; then
  NETHOST_LIB_DIR="$INC_DIR"
else
  NETHOST_LIB_DIR="$(dirname "$(find "$DOTNET_ROOT/packs" -type f -name libnethost.so -print -quit)")"
fi

# Sanity prints (optional)
echo "HOSTFXR_LIB_DIR=$HOSTFXR_LIB_DIR"
echo "INC_DIR=$INC_DIR"
echo "NETHOST_LIB_DIR=$NETHOST_LIB_DIR"

# Compile
g++ -o host host.cpp \
  ${INC_DIRS:-} \
  -L"$HOSTFXR_LIB_DIR" -L"$NETHOST_LIB_DIR" \
  -Wl,-rpath,"$HOSTFXR_LIB_DIR:$NETHOST_LIB_DIR" \
  -ldl -lhostfxr -lnethost

# ===== 4) Run: place host next to managed bits ================================
# Put host beside ManagedLibrary.dll + ManagedLibrary.runtimeconfig.json
cp host ../ManagedLibrary/bin/Release/net9.0/

cd ../ManagedLibrary/bin/Release/net9.0/
ls -1 | head -n 5
./host

