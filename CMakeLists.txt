cmake_minimum_required(VERSION 3.20)
project(hostclr_hello C CXX)

# -------- Config knobs -----------------
set(DOTNET_EXECUTABLE "dotnet" CACHE STRING "dotnet CLI path")
set(CONFIG "Release" CACHE STRING "Build configuration for dotnet")
set(TFM "net9.0" CACHE STRING "Target Framework Moniker")
set(MANAGED_PROJ_DIR "${CMAKE_SOURCE_DIR}/ManagedLibrary")
set(NATIVE_DIR "${CMAKE_SOURCE_DIR}/NativeHost")

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

# -------- Discover nethost (Linux defaults; overridable) --------
# Let users override these via cache if needed:
set(DOTNET_ROOT $ENV{DOTNET_ROOT})
if(NOT DOTNET_ROOT)
    # Typical Linux location for distro packages
    set(DOTNET_ROOT "/usr/share/dotnet")
endif()

# Try to detect the latest Microsoft.NETCore.App.Host pack version:
file(GLOB HOST_PACK_DIRS
        "${DOTNET_ROOT}/packs/Microsoft.NETCore.App.Host.linux-x64/*")
if(HOST_PACK_DIRS)
    list(SORT HOST_PACK_DIRS)
    list(REVERSE HOST_PACK_DIRS)
    list(GET HOST_PACK_DIRS 0 HOST_PACK_DIR)  # pick newest
else()
    message(FATAL_ERROR
            "Could not find Microsoft.NETCore.App.Host.linux-x64 pack under ${DOTNET_ROOT}/packs.\n"
            "Make sure the .NET SDK is installed. You can override detection by setting:\n"
            "  -DNETHOST_INCLUDE_DIR=/path/...  -DNETHOST_LIB=/path/...")
endif()

set(DEFAULT_NETHOST_NATIVE_DIR
        "${HOST_PACK_DIR}/runtimes/linux-x64/native")

# Allow manual override via -DNETHOST_INCLUDE_DIR and -DNETHOST_LIB
set(NETHOST_INCLUDE_DIR "${DEFAULT_NETHOST_NATIVE_DIR}" CACHE PATH "Path containing nethost.h")
set(NETHOST_LIB "" CACHE FILEPATH "Full path to libnethost (e.g., /.../libnethost.so)")

if(NOT EXISTS "${NETHOST_INCLUDE_DIR}/nethost.h")
    message(FATAL_ERROR "nethost.h not found in ${NETHOST_INCLUDE_DIR}. "
            "Set -DNETHOST_INCLUDE_DIR=/path/to/dir that contains nethost.h")
endif()

if(NOT NETHOST_LIB)
    # Try to pick the lib from the same native dir
    if(EXISTS "${DEFAULT_NETHOST_NATIVE_DIR}/libnethost.so")
        set(NETHOST_LIB "${DEFAULT_NETHOST_NATIVE_DIR}/libnethost.so")
    elseif(EXISTS "${DEFAULT_NETHOST_NATIVE_DIR}/libnethost.a")
        set(NETHOST_LIB "${DEFAULT_NETHOST_NATIVE_DIR}/libnethost.a")
    endif()
endif()
if(NOT NETHOST_LIB)
    message(FATAL_ERROR "Could not locate libnethost in ${DEFAULT_NETHOST_NATIVE_DIR}. "
            "Set -DNETHOST_LIB=/path/to/libnethost.so")
endif()

message(STATUS "DOTNET_ROOT: ${DOTNET_ROOT}")
message(STATUS "Using nethost include: ${NETHOST_INCLUDE_DIR}")
message(STATUS "Using nethost lib:     ${NETHOST_LIB}")

# -------- Native host target (pure CMake) -----------------------
# Collect C/C++ sources in NativeHost/ (adjust patterns if needed)
file(GLOB HOST_SOURCES
        "${NATIVE_DIR}/*.c"
        "${NATIVE_DIR}/*.cc"
        "${NATIVE_DIR}/*.cpp")

if(NOT HOST_SOURCES)
    message(FATAL_ERROR "No host sources found under ${NATIVE_DIR}. "
            "Add your host .c/.cpp file(s) there.")
endif()

add_executable(host_native ${HOST_SOURCES})
target_include_directories(host_native PRIVATE "${NETHOST_INCLUDE_DIR}")

# Linux needs dl (for dlopen of hostfxr) and pthread (often harmless/standard).
# You generally do NOT link hostfxr—your code loads it via nethost at runtime.
if(UNIX AND NOT APPLE)
    target_link_libraries(host_native PRIVATE "${NETHOST_LIB}" dl pthread)
elseif(APPLE)
    target_link_libraries(host_native PRIVATE "${NETHOST_LIB}")
elseif(WIN32)
    # On Windows, nethost is a static .lib by default; no dl needed.
    target_link_libraries(host_native PRIVATE "${NETHOST_LIB}")
endif()

# Put the native binary somewhere stable in the build tree
set_target_properties(host_native PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/native")

# After building native + managed, copy the host next to the managed outputs
add_custom_command(TARGET host_native POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:host_native>" "${FINAL_HOST_BIN}"
        COMMENT "Staging host next to managed outputs: ${FINAL_HOST_BIN}"
)

# Ensure native copies only after managed publish exists
add_dependencies(host_native managed)

# -------- Expose a runnable target for CLion --------------------
# We'll run the staged binary in the managed folder.
add_executable(hostclr IMPORTED GLOBAL)
set_target_properties(hostclr PROPERTIES
        IMPORTED_LOCATION "${FINAL_HOST_BIN}"
)
add_dependencies(hostclr host_native managed)

# -------- Optional: ctest to run it -----------------------------
enable_testing()
add_test(NAME run_hostclr
        COMMAND "${FINAL_HOST_BIN}"
        WORKING_DIRECTORY "${MANAGED_OUT}"
)
