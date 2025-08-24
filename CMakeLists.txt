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

# -------- Unified output directory at project root --------
set(OUTPUT_DIR "${CMAKE_SOURCE_DIR}/build")
file(MAKE_DIRECTORY "${OUTPUT_DIR}")

# Managed artifacts that dotnet will publish into OUTPUT_DIR
set(MANAGED_DLL         "${OUTPUT_DIR}/ManagedLibrary.dll")
set(MANAGED_RUNTIMECFG  "${OUTPUT_DIR}/ManagedLibrary.runtimeconfig.json")

# Final runnable host path (native exe emitted into OUTPUT_DIR as "host")
set(FINAL_HOST_BIN "${OUTPUT_DIR}/host")

# -------- Managed build (dotnet publish -> ${PROJECT_ROOT}/build) --------
add_custom_command(
        OUTPUT  "${MANAGED_DLL}" "${MANAGED_RUNTIMECFG}"
        COMMAND "${DOTNET_EXECUTABLE}" publish "${MANAGED_PROJ_DIR}"
        -c "${CONFIG}" -f "${TFM}" -o "${OUTPUT_DIR}"
        WORKING_DIRECTORY "${MANAGED_PROJ_DIR}"
        COMMENT "Publishing ManagedLibrary (${CONFIG}|${TFM}) to ${OUTPUT_DIR}"
        VERBATIM
)
add_custom_target(managed ALL
        DEPENDS "${MANAGED_DLL}" "${MANAGED_RUNTIMECFG}"
)

# -------- Discover nethost / hostfxr (Linux defaults; overridable) --------
set(DOTNET_ROOT $ENV{DOTNET_ROOT})
if(NOT DOTNET_ROOT)
    set(DOTNET_ROOT "/usr/share/dotnet")
endif()

file(GLOB HOST_PACK_DIRS "${DOTNET_ROOT}/packs/Microsoft.NETCore.App.Host.${DOTNET_RID}/*")
if(HOST_PACK_DIRS)
    list(SORT HOST_PACK_DIRS)
    list(REVERSE HOST_PACK_DIRS)
    list(GET HOST_PACK_DIRS 0 HOST_PACK_DIR)  # newest
else()
    message(FATAL_ERROR
            "Could not find Microsoft.NETCore.App.Host.${DOTNET_RID} under ${DOTNET_ROOT}/packs.\n"
            "Set overrides: -DNETHOST_INCLUDE_DIR=  -DNETHOST_LIB=  -DHOSTFXR_INCLUDE_DIR=")
endif()

set(DEFAULT_NETHOST_NATIVE_DIR "${HOST_PACK_DIR}/runtimes/${DOTNET_RID}/native")
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

set(NETHOST_INCLUDE_DIR "${DEFAULT_NETHOST_NATIVE_DIR}" CACHE PATH "Dir that contains nethost.h")
set(HOSTFXR_INCLUDE_DIR "${DEFAULT_HOSTFXR_INCLUDE_DIR}" CACHE PATH "Dir that contains hostfxr.h & coreclr_delegates.h")
set(NETHOST_LIB "" CACHE FILEPATH "Full path to libnethost (e.g., /.../libnethost.so)")

if(NOT EXISTS "${NETHOST_INCLUDE_DIR}/nethost.h")
    message(FATAL_ERROR "nethost.h not found in ${NETHOST_INCLUDE_DIR}. Set -DNETHOST_INCLUDE_DIR=/path/to/dir containing nethost.h")
endif()
if(NOT EXISTS "${HOSTFXR_INCLUDE_DIR}/hostfxr.h")
    message(FATAL_ERROR "hostfxr.h not found in ${HOSTFXR_INCLUDE_DIR}. Set -DHOSTFXR_INCLUDE_DIR=/path/to/dir containing hostfxr.h")
endif()
if(NOT EXISTS "${HOSTFXR_INCLUDE_DIR}/coreclr_delegates.h")
    message(FATAL_ERROR "coreclr_delegates.h not found in ${HOSTFXR_INCLUDE_DIR}. Set -DHOSTFXR_INCLUDE_DIR=/path/to/dir containing coreclr_delegates.h")
endif()

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
message(STATUS "Unified OUTPUT_DIR:    ${OUTPUT_DIR}")

# -------- Native host target (emits directly to ${PROJECT_ROOT}/build) ------
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

if(UNIX AND NOT APPLE)
    target_link_libraries(host_native PRIVATE "${NETHOST_LIB}" dl pthread)
    target_link_options(host_native PRIVATE "-Wl,--export-dynamic")
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
    target_link_libraries(host_native PRIVATE "${NETHOST_LIB}")
    set_target_properties(host_native PROPERTIES ENABLE_EXPORTS ON)
endif()

# Emit the native exe directly into ${PROJECT_ROOT}/build as "host"
set_target_properties(host_native PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
        OUTPUT_NAME "host"
)

# Ensure native waits for managed publish (so runtimeconfig is present)
add_dependencies(host_native managed)

# Also copy libnethost.so beside the staged host on Unix (extra safety)
if(UNIX AND NOT APPLE)
    get_filename_component(NETHOST_LIB_NAME "${NETHOST_LIB}" NAME)
    add_custom_command(TARGET host_native POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "${NETHOST_LIB}" "${OUTPUT_DIR}/${NETHOST_LIB_NAME}"
            COMMENT "Copying ${NETHOST_LIB_NAME} to ${OUTPUT_DIR}"
    )
endif()

# -------- Runnable/imported target and CTest ---------------------
add_executable(hostclr IMPORTED GLOBAL)
set_target_properties(hostclr PROPERTIES IMPORTED_LOCATION "${FINAL_HOST_BIN}")
add_dependencies(hostclr host_native managed)

enable_testing()
add_test(NAME run_hostclr
        COMMAND "${FINAL_HOST_BIN}"
        WORKING_DIRECTORY "${OUTPUT_DIR}"
)
