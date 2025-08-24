cmake_minimum_required(VERSION 3.20)
project(hostclr_hello C)

# -------- Config knobs (tweak as needed) -----------------
set(DOTNET_EXECUTABLE "dotnet" CACHE STRING "dotnet CLI path")
set(CONFIG "Release" CACHE STRING "Build configuration for dotnet")
set(TFM "net9.0" CACHE STRING "Target Framework Moniker")
set(MANAGED_PROJ_DIR "${CMAKE_SOURCE_DIR}/ManagedLibrary")
set(NATIVE_DIR "${CMAKE_SOURCE_DIR}/NativeHost")

# Where we place the published managed bits:
set(MANAGED_OUT "${CMAKE_BINARY_DIR}/managed/${CONFIG}/${TFM}")

# Where we place the built native host binary before copying next to managed:
set(NATIVE_OUT_DIR "${CMAKE_BINARY_DIR}/native")
set(NATIVE_HOST_BIN "${NATIVE_OUT_DIR}/host")

# Final runnable bundle (host next to managed dll/runtimeconfig):
set(FINAL_HOST_BIN "${MANAGED_OUT}/host")

# -------- Managed build (dotnet publish) -----------------
# Publish produces: ManagedLibrary.dll + ManagedLibrary.runtimeconfig.json (and deps)
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

# -------- Native host build (reuse your script) ----------
# We call your build_host.sh, then copy the result to a known location in the build tree.
add_custom_command(
        OUTPUT "${NATIVE_HOST_BIN}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${NATIVE_OUT_DIR}"
        COMMAND /usr/bin/env bash -lc "cd '${NATIVE_DIR}' && chmod +x build_host.sh && ./build_host.sh"
        COMMAND ${CMAKE_COMMAND} -E copy "${NATIVE_DIR}/host" "${NATIVE_HOST_BIN}"
        WORKING_DIRECTORY "${NATIVE_DIR}"
        COMMENT "Building native host via build_host.sh and staging to ${NATIVE_HOST_BIN}"
        VERBATIM
)
add_custom_target(native_host ALL
        DEPENDS "${NATIVE_HOST_BIN}"
)

# -------- Bundle: place host next to managed outputs -----
add_custom_command(
        OUTPUT "${FINAL_HOST_BIN}"
        COMMAND ${CMAKE_COMMAND} -E copy "${NATIVE_HOST_BIN}" "${FINAL_HOST_BIN}"
        DEPENDS native_host managed
        COMMENT "Copying host next to ManagedLibrary outputs"
        VERBATIM
)
add_custom_target(package_run ALL
        DEPENDS "${FINAL_HOST_BIN}"
)

# -------- Make the final runnable visible to CLion -------
# Expose an IMPORTED executable that points to the generated 'host' binary.
add_executable(hostclr IMPORTED GLOBAL)
set_target_properties(hostclr PROPERTIES
        IMPORTED_LOCATION "${FINAL_HOST_BIN}"
)
add_dependencies(hostclr package_run)

# -------- Optional: ctest to run it ----------------------
enable_testing()
add_test(NAME run_hostclr
        COMMAND "${FINAL_HOST_BIN}"
        WORKING_DIRECTORY "${MANAGED_OUT}"
)
