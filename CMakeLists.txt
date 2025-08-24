cmake_minimum_required(VERSION 3.20)
project(hostclr_hello C CXX)

# -------- Toolchain / language -----------------
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# -------- Config knobs -----------------
set(DOTNET_EXECUTABLE "dotnet" CACHE STRING "dotnet CLI path")
set(CONFIG "Release" CACHE STRING "Build configuration for dotnet")
set(TFM "net9.0" CACHE STRING "Target Framework Moniker")
set(MANAGED_PROJ_DIR "${CMAKE_SOURCE_DIR}/ManagedLibrary")
set(NATIVE_DIR "${CMAKE_SOURCE_DIR}/NativeHost")

# Allow override of the .NET Runtime Identifier (RID)
set(DOTNET_RID "" CACHE STRING "dotnet RID, e.g. linux-x64 | linux-arm64 | linux-arm")
if(NOT DOTNET_RID)
    if(UNIX AND NOT APPLE)
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|amd64")
            set(DOTNET_RID "linux-x64")
        elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
            set(DOTNET_RID "linux-arm64")
        elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "armv7l|armv8l|armv7")
            set(DOTNET_RID "linux-arm")
        else()
            set(DOTNET_RID "linux-x64") # fallback
        endif()
    endif()
endif()

# Managed publish output folder in CMake build tree:
set(MANAGED_OUT "${CMAKE_BINARY_DIR}/managed/${CONFIG}/${TFM}")

# Final runnable binary path:
set(FINAL_HOST_BIN "${MANAGED_OUT}/host")

# -------- Managed build (dotnet publish) -----------------
add_custom_command(
        OUTPUT "${MANAGED_OUT}/ManagedLibrary.dll" "${MANAGED_OUT}/ManagedLibrary.runtimeconfig.json"
        COMMAND "${DOTNET_EXECUTABLE}" publish "${MANAGED_PROJ_DIR}" -c "${CONFIG}" -f "${TFM}" -o "${MANAGED_OUT}"
        WORKING_DIRECTORY "${MANAGED_PROJ_DIR}"
        COMMENT "Publishing ManagedLibrary (${CONFIG}|${TFM}) to ${MANAGED_OUT}"
        VERBATIM
)
add_custom_target(managed ALL
        DEPENDS "${MANAGED_OUT}/ManagedLibrary.dll" "${MANAGED_OUT}/ManagedLibrary.runtimeconfig.json"
)

# -------- Discover nethost / hostfxr (Linux defaults; overridable) --------
set(DOTNET_ROOT $ENV{DOTNET_ROOT})
if(NOT DOTNET_ROOT)
    set(DOTNET_ROOT "/usr/share/dotnet")
endif()

# Pack path varies by RID
file(GLOB HOST_PACK_DIRS "${DOTNET_ROOT}/packs/Microsoft.NETCore.App.Host.${DOTNET_RID}/*")
if(HOST_PACK_DIRS)
    list(SORT HOST_PACK_DIRS)
    list(REVERSE HOST_PACK_DIRS)
    list(GET HOST_PACK_DIRS 0 HOST_PACK_DIR)  # newest
else()
    message(FATAL_ERROR
            "Could not find Microsoft.NETCore.App.Host.${DOTNET_RID} pack under ${DOTNET_ROOT}/packs.\n"
            "Ensure the .NET SDK is installed or set overrides:\n"
            "  -DNETHOST_INCLUDE_DIR=  -DNETHOST_LIB=  -DHOSTFXR_INCLUDE_DIR=")
endif()

# Default locations inside the Host pack
set(DEFAULT_NETHOST_NATIVE_DIR "${HOST_PACK_DIR}/runtimes/${DOTNET_RID}/native")

# Hostfxr & CoreCLR headers live in one of these on different SDKs/installers
set(_HOSTFXR_CANDIDATES
        "${HOST_PACK_DIR}/runtimes/${DOTNET_RID}/native"
        "${HOST_PACK_DIR}/include"
)

unset(DEFAULT_HOSTFXR_INCLUDE_DIR)
foreach(dir IN LISTS _HOSTFXR_CANDIDATES)
    if(EXISTS "${dir}/hostfxr.h" AND EXISTS "${dir}/coreclr_delegates.h")
        set(DEFAULT_HOSTFXR_INCLUDE_DIR "${dir}")
        break()
    endif()
endforeach()

if(NOT DEFAULT_HOSTFXR_INCLUDE_DIR)
    message(FATAL_ERROR
            "Could not find hostfxr.h & coreclr_delegates.h under:\n"
            "  ${HOST_PACK_DIR}/runtimes/${DOTNET_RID}/native\n"
            "  ${HOST_PACK_DIR}/include")
endif()

# Allow manual override
set(NETHOST_INCLUDE_DIR "${DEFAULT_NETHOST_NATIVE_DIR}" CACHE PATH "Dir that contains nethost.h")
set(HOSTFXR_INCLUDE_DIR "${DEFAULT_HOSTFXR_INCLUDE_DIR}" CACHE PATH "Dir that contains hostfxr.h & coreclr_delegates.h")
set(NETHOST_LIB "" CACHE FILEPATH "Full path to libnethost (e.g., /.../libnethost.so)")

# Validate headers
if(NOT EXISTS "${NETHOST_INCLUDE_DIR}/nethost.h")
    message(FATAL_ERROR "nethost.h not found in ${NETHOST_INCLUDE_DIR}. Set -DNETHOST_INCLUDE_DIR=/path/to/dir containing nethost.h")
endif()
if(NOT EXISTS "${HOSTFXR_INCLUDE_DIR}/hostfxr.h")
    message(FATAL_ERROR "hostfxr.h not found in ${HOSTFXR_INCLUDE_DIR}. Set -DHOSTFXR_INCLUDE_DIR=/path/to/dir containing hostfxr.h")
endif()
if(NOT EXISTS "${HOSTFXR_INCLUDE_DIR}/coreclr_delegates.h")
    message(FATAL_ERROR "coreclr_delegates.h not found in ${HOSTFXR_INCLUDE_DIR}. Set -DHOSTFXR_INCLUDE_DIR=/path/to/dir containing coreclr_delegates.h")
endif()

# Pick libnethost if not provided
if(NOT NETHOST_LIB)
    if(EXISTS "${DEFAULT_NETHOST_NATIVE_DIR}/libnethost.so")
        set(NETHOST_LIB "${DEFAULT_NETHOST_NATIVE_DIR}/libnethost.so")
    elseif(EXISTS "${DEFAULT_NETHOST_NATIVE_DIR}/libnethost.a")
        set(NETHOST_LIB "${DEFAULT_NETHOST_NATIVE_DIR}/libnethost.a")
    endif()
endif()
if(NOT NETHOST_LIB)
    message(FATAL_ERROR "Could not locate libnethost in ${DEFAULT_NETHOST_NATIVE_DIR}. Set -DNETHOST_LIB=/path/to/libnethost.so")
endif()

message(STATUS "DOTNET_ROOT:           ${DOTNET_ROOT}")
message(STATUS "DOTNET_RID:            ${DOTNET_RID}")
message(STATUS "Using nethost include: ${NETHOST_INCLUDE_DIR}")
message(STATUS "Using hostfxr include: ${HOSTFXR_INCLUDE_DIR}")
message(STATUS "Using nethost lib:     ${NETHOST_LIB}")

# -------- Native host target (pure CMake) -----------------------
file(GLOB HOST_SOURCES
        "${NATIVE_DIR}/*.c"
        "${NATIVE_DIR}/*.cc"
        "${NATIVE_DIR}/*.cpp"
)
if(NOT HOST_SOURCES)
    message(FATAL_ERROR "No host sources found under ${NATIVE_DIR}. Add your host .c/.cpp file(s) there.")
endif()

add_executable(host_native ${HOST_SOURCES})
target_include_directories(host_native PRIVATE "${NETHOST_INCLUDE_DIR}" "${HOSTFXR_INCLUDE_DIR}")

# Link nethost + needed system libs; add exports + RPATH so __Internal works and libnethost is found.
if(UNIX AND NOT APPLE)
    target_link_libraries(host_native PRIVATE "${NETHOST_LIB}" dl pthread)
    # Export native symbols from the executable for DllImport("__Internal")
    target_link_options(host_native PRIVATE "-Wl,--export-dynamic")
    # Prefer the local copy next to the staged host; also fall back to the pack path.
    set_target_properties(host_native PROPERTIES
            BUILD_RPATH "\$ORIGIN;${DEFAULT_NETHOST_NATIVE_DIR}"
            INSTALL_RPATH "\$ORIGIN"
    )
elseif(APPLE)
    target_link_libraries(host_native PRIVATE "${NETHOST_LIB}")
    target_link_options(host_native PRIVATE "-Wl,-export_dynamic")
    set_target_properties(host_native PROPERTIES
            BUILD_RPATH "@loader_path"
            INSTALL_RPATH "@loader_path"
    )
elseif(WIN32)
    # On Windows, nethost is usually a static .lib; exporting isn't needed for __Internal.
    target_link_libraries(host_native PRIVATE "${NETHOST_LIB}")
    set_target_properties(host_native PROPERTIES ENABLE_EXPORTS ON)
endif()

# Put the native binary somewhere stable in the build tree
set_target_properties(host_native PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/native"
)

# After building native + managed, copy the host next to the managed outputs
add_custom_command(TARGET host_native POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:host_native>" "${FINAL_HOST_BIN}"
        COMMENT "Staging host next to managed outputs: ${FINAL_HOST_BIN}"
)

# Also copy libnethost.so beside the staged host on Unix (extra safety)
if(UNIX AND NOT APPLE)
    get_filename_component(NETHOST_LIB_NAME "${NETHOST_LIB}" NAME)
    add_custom_command(TARGET host_native POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "${NETHOST_LIB}" "${MANAGED_OUT}/${NETHOST_LIB_NAME}"
            COMMENT "Copying ${NETHOST_LIB_NAME} to ${MANAGED_OUT}"
    )
endif()

# Ensure native copies only after managed publish exists
add_dependencies(host_native managed)

# -------- Expose a runnable target for CLion --------------------
add_executable(hostclr IMPORTED GLOBAL)
set_target_properties(hostclr PROPERTIES IMPORTED_LOCATION "${FINAL_HOST_BIN}")
add_dependencies(hostclr host_native managed)

# -------- Optional: ctest to run it -----------------------------
enable_testing()
add_test(NAME run_hostclr
        COMMAND "${FINAL_HOST_BIN}"
        WORKING_DIRECTORY "${MANAGED_OUT}"
)
