if(NOT CMAKE_INSTALL_PREFIX STREQUAL "/usr")
    message(FATAL_ERROR "Debian packages require CMAKE_INSTALL_PREFIX=/usr. Use the debian preset or make deb.")
endif()
if(NOT CMAKE_BUILD_TYPE STREQUAL "Release")
    message(FATAL_ERROR "Debian packages require a Release build.")
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_program(INZONE_DPKG dpkg REQUIRED)
find_program(INZONE_DPKG_SHLIBDEPS dpkg-shlibdeps REQUIRED)
find_program(INZONE_PATCHELF patchelf REQUIRED)
find_program(INZONE_MAKE make REQUIRED)
execute_process(COMMAND "${INZONE_DPKG}" --print-architecture
    OUTPUT_VARIABLE INZONE_DEBIAN_ARCHITECTURE OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
set(INZONE_NATIVE_MAKE_ARGUMENTS "" CACHE STRING "Additional native DSP make arguments")
set(INZONE_DEBIAN_RELEASE "1" CACHE STRING "Debian package revision")
set(INZONE_PACKAGE_DIRECTORY "${CMAKE_BINARY_DIR}/packages" CACHE PATH "Debian package output directory")

file(GLOB_RECURSE INZONE_COMMAND_SOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/Sources/*.swift")
set(INZONE_PROFILE_BINARY "${INZONE_SWIFTPM_SCRATCH_PATH}/release/inzone-profile")
set(INZONE_TOOLS_BINARY "${INZONE_SWIFTPM_SCRATCH_PATH}/release/inzone-tools")
add_custom_command(OUTPUT "${INZONE_PROFILE_BINARY}" "${INZONE_TOOLS_BINARY}"
    COMMAND "${CMAKE_COMMAND}" -E env
        --unset=CC --unset=CXX --unset=LD --unset=AR --unset=CFLAGS --unset=CXXFLAGS --unset=LDFLAGS
        "${INZONE_SWIFT_EXECUTABLE}" build --package-path "${CMAKE_SOURCE_DIR}"
        --scratch-path "${INZONE_SWIFTPM_SCRATCH_PATH}" --configuration release
        --static-swift-stdlib --disable-automatic-resolution ${INZONE_SWIFTPM_FLAGS}
    DEPENDS ${INZONE_COMMAND_SOURCES} "${CMAKE_SOURCE_DIR}/Package.swift" "${CMAKE_SOURCE_DIR}/Package.resolved"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Building the packaged CLI and setup utility" VERBATIM)
add_custom_target(inzone-package-commands ALL DEPENDS "${INZONE_PROFILE_BINARY}" "${INZONE_TOOLS_BINARY}")
# SwiftPM uses one database per scratch directory and must not run two builds concurrently.
add_dependencies(inzone-package-commands inzone-service)

set(INZONE_DSP_BINARY "${CMAKE_BINARY_DIR}/native/inzone_dsp.so")
file(GLOB INZONE_DSP_SOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/Sources/InzoneDSP/*.swift")
add_custom_target(inzone-package-dsp ALL
    COMMAND "${INZONE_MAKE}" -B -C "${CMAKE_SOURCE_DIR}/native"
        "OUTPUT=${INZONE_DSP_BINARY}" "DEBUG_OBJECT=${CMAKE_BINARY_DIR}/native/debug.o"
        "SWIFTC=${CMAKE_Swift_COMPILER}" "MODULE_CACHE=${CMAKE_BINARY_DIR}/native-module-cache" ${INZONE_NATIVE_MAKE_ARGUMENTS}
    BYPRODUCTS "${INZONE_DSP_BINARY}"
    DEPENDS ${INZONE_DSP_SOURCES} "${CMAKE_SOURCE_DIR}/native/Makefile"
    COMMENT "Building the packaged LADSPA plugin" VERBATIM)

install(PROGRAMS "${INZONE_PROFILE_BINARY}" "${INZONE_TOOLS_BINARY}" DESTINATION bin)
install(PROGRAMS "${INZONE_DSP_BINARY}" DESTINATION lib/ladspa)
install(FILES configs/udev/70-inzone-h9-ii.rules DESTINATION lib/udev/rules.d)
file(READ "${CMAKE_SOURCE_DIR}/configs/systemd/inzone-profile-auto.service" INZONE_AUTO_UNIT)
string(REPLACE "%h/.local/bin/inzone-profile" "/usr/bin/inzone-profile" INZONE_AUTO_UNIT "${INZONE_AUTO_UNIT}")
file(WRITE "${CMAKE_BINARY_DIR}/inzone-profile-auto.service" "${INZONE_AUTO_UNIT}")
install(FILES "${CMAKE_BINARY_DIR}/inzone-profile-auto.service" configs/systemd/inzone-filter-chain.service
    DESTINATION lib/systemd/user)

# User configuration and Sony assets are initialized explicitly by the desktop user.
install(DIRECTORY configs/ DESTINATION share/inzone-linux/setup/configs
    PATTERN "*.in" EXCLUDE)
install(DIRECTORY docs/ DESTINATION share/inzone-linux/setup/docs)
install(FILES README.md DESTINATION share/inzone-linux/setup)
install(FILES evidence/installer.json DESTINATION share/inzone-linux/setup/evidence)
install(FILES packaging/debian/copyright DESTINATION share/doc/inzone-linux)
install(FILES packaging/debian/lintian-overrides DESTINATION share/lintian/overrides RENAME inzone-linux)
install(FILES LICENSE DESTINATION share/doc/inzone-linux RENAME LICENSE.inzone-linux)
install(FILES docs/debian.md DESTINATION share/doc/inzone-linux)
install(FILES packaging/debian/dev.zeroday0619.InzoneControl.metainfo.xml DESTINATION share/metainfo)
install(DIRECTORY packaging/debian/man/ DESTINATION share/man/man1 FILES_MATCHING PATTERN "*.1")
install(DIRECTORY "${qtbridge_SOURCE_DIR}/LICENSES/" DESTINATION share/doc/inzone-linux/licenses/qtbridge)
install(FILES "${qtbridge_SOURCE_DIR}/LICENSE.txt" DESTINATION share/doc/inzone-linux/licenses/qtbridge)

set(INZONE_SWIFT_RUNTIME_DIRECTORY "${INZONE_SWIFT_DIRECTORY}/../lib/swift/linux")
set(INZONE_RUNTIME_INSTALL_SCRIPT "${CMAKE_BINARY_DIR}/InstallDebianRuntime.cmake")
configure_file("${CMAKE_SOURCE_DIR}/cmake/InstallDebianRuntime.cmake.in" "${INZONE_RUNTIME_INSTALL_SCRIPT}" @ONLY)
install(SCRIPT "${INZONE_RUNTIME_INSTALL_SCRIPT}")

set(CPACK_GENERATOR DEB)
set(CPACK_PACKAGE_NAME inzone-linux)
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_PACKAGE_CONTACT "Euiseo Cha <escha@zeroday0619.dev>")
set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/zeroday0619/inzone-linux")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "INZONE headset control with a native Qt desktop")
set(CPACK_PACKAGE_DESCRIPTION "Swift CLI, Qt Quick desktop, session D-Bus service, and LADSPA DSP\nfor Sony INZONE headsets. Proprietary Sony assets are acquired\nseparately by the desktop user.")
set(CPACK_PACKAGE_DIRECTORY "${INZONE_PACKAGE_DIRECTORY}")
set(CPACK_PACKAGING_INSTALL_PREFIX /usr)
set(CPACK_SET_DESTDIR ON)
set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)
set(CPACK_DEBIAN_PACKAGE_RELEASE "${INZONE_DEBIAN_RELEASE}")
set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "${INZONE_DEBIAN_ARCHITECTURE}")
set(CPACK_DEBIAN_PACKAGE_SECTION sound)
set(CPACK_DEBIAN_PACKAGE_PRIORITY optional)
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
set(CPACK_DEBIAN_PACKAGE_DEPENDS "pipewire-bin, pipewire-pulse, wireplumber (>= 0.5), pulseaudio-utils, dbus-user-session, udev")
if(NOT INZONE_BUNDLED_QT_PREFIX)
    string(APPEND CPACK_DEBIAN_PACKAGE_DEPENDS ", qml6-module-qtquick, qml6-module-qtquick-window, qml6-module-qtquick-layouts, qml6-module-qtquick-controls, qml6-module-qtquick-templates, qml6-module-qtqml-workerscript, qt6-wayland")
endif()
set(CPACK_DEBIAN_PACKAGE_SUGGESTS "7zip")
set(CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA "${CMAKE_SOURCE_DIR}/packaging/debian/postinst;${CMAKE_SOURCE_DIR}/packaging/debian/postrm")
set(CPACK_DEBIAN_PACKAGE_CONTROL_STRICT_PERMISSION TRUE)
set(CPACK_DEBIAN_COMPRESSION_TYPE xz)
include(CPack)
