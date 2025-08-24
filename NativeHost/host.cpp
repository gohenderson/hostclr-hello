// host.cpp
#include <iostream>
#include <string>

// .NET hosting headers
#include <nethost.h>
#include <coreclr_delegates.h>
#include <hostfxr.h>

// POSIX / Linux bits we were missing
#include <dlfcn.h>     // dlopen, dlsym, RTLD_*
#include <limits.h>    // PATH_MAX
#include <unistd.h>    // readlink
#include <libgen.h>    // dirname
#include <string.h>

// Helper to load hostfxr and get needed exports
struct hostfxr_exports {
    hostfxr_initialize_for_runtime_config_fn initialize = nullptr;
    hostfxr_get_runtime_delegate_fn           get_delegate = nullptr;
    hostfxr_close_fn                          close = nullptr;
    void*                                     lib_handle = nullptr;
};

static bool load_hostfxr_exports(hostfxr_exports& out, const std::string& runtimeconfig_path)
{
    char hostfxr_path[1024];
    size_t size = sizeof(hostfxr_path);

    get_hostfxr_parameters params;
    memset(&params, 0, sizeof(params));
    params.size = sizeof(params);
    // Point to the runtimeconfig so hostfxr is resolved beside it
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

int main(int /*argc*/, char* /*argv*/[]) {
    // Determine the directory of the current executable
    char exe_path[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path));
    if (len <= 0 || len >= (ssize_t)sizeof(exe_path)) {
        std::cerr << "Failed to get /proc/self/exe\n";
        return 1;
    }
    exe_path[len] = '\0';
    std::string exe_dir = dirname(exe_path);

    // Managed assembly paths (place host next to published DLL + runtimeconfig)
    std::string assembly_path = exe_dir + "/ManagedLibrary.dll";
    std::string runtimeconfig_path = exe_dir + "/ManagedLibrary.runtimeconfig.json";

    // Load hostfxr + exports
    hostfxr_exports fxr{};
    if (!load_hostfxr_exports(fxr, runtimeconfig_path)) {
        return 1;
    }

    // Initialize .NET runtime from the runtimeconfig
    hostfxr_handle cxt = nullptr;
    int rc = fxr.initialize(runtimeconfig_path.c_str(), nullptr, &cxt);
    if (rc != 0 || cxt == nullptr) {
        std::cerr << "hostfxr_initialize_for_runtime_config failed, rc=" << rc << "\n";
        return 1;
    }

    // Get the load_assembly_and_get_function_pointer delegate
    load_assembly_and_get_function_pointer_fn load_asm_and_get_ptr = nullptr;
    rc = fxr.get_delegate(cxt,
                          hdt_load_assembly_and_get_function_pointer,
                          (void**)&load_asm_and_get_ptr);
    if (rc != 0 || load_asm_and_get_ptr == nullptr) {
        std::cerr << "hostfxr_get_runtime_delegate failed, rc=" << rc << "\n";
        fxr.close(cxt);
        return 1;
    }

    // Get the function pointer to the UnmanagedCallersOnly method
    typedef void (CORECLR_DELEGATE_CALLTYPE *say_hello_fn)();
    say_hello_fn say_hello = nullptr;

    rc = load_asm_and_get_ptr(
        assembly_path.c_str(),
        "ManagedLibrary.Library, ManagedLibrary",
        "SayHello", // <-- use the managed method name (PascalCase)
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
