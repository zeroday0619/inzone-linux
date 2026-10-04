cmake_minimum_required(VERSION 3.29)
project(InzoneLinux VERSION 0.1.0 LANGUAGES C CXX Swift)

include(GNUInstallDirs)
include(FetchContent)
option(INZONE_DEBIAN_PACKAGE "Build a complete Debian binary package" OFF)
set(INZONE_BUNDLED_QT_PREFIX "" CACHE PATH "Optional Qt SDK bundled in the Debian package")
if(INZONE_BUNDLED_QT_PREFIX)
    list(PREPEND CMAKE_PREFIX_PATH "${INZONE_BUNDLED_QT_PREFIX}")
endif()
find_package(PkgConfig REQUIRED)
find_package(Qt6 6.10 REQUIRED COMPONENTS Core Gui Qml Quick WaylandClient)
if(INZONE_BUNDLED_QT_PREFIX)
    file(REAL_PATH "${INZONE_BUNDLED_QT_PREFIX}" INZONE_REAL_QT_PREFIX)
    file(REAL_PATH "${Qt6Core_DIR}" INZONE_QT_CORE_DIRECTORY)
    cmake_path(IS_PREFIX INZONE_REAL_QT_PREFIX "${INZONE_QT_CORE_DIRECTORY}" NORMALIZE INZONE_QT_MATCHES_BUNDLE)
    if(NOT INZONE_QT_MATCHES_BUNDLE)
        message(FATAL_ERROR "The build and bundled Qt SDK must match. Configure a clean build directory with the requested Qt prefix.")
    endif()
endif()
find_package(Qt6QWaylandIntegrationPlugin QUIET
    PATHS "${Qt6Gui_DIR}" "${Qt6WaylandClient_DIR}"
)
if(NOT TARGET Qt6::QWaylandIntegrationPlugin)
    message(FATAL_ERROR "The Qt Wayland platform plugin is required to build the desktop interface.")
endif()
pkg_check_modules(SYSTEMD REQUIRED IMPORTED_TARGET libsystemd)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# QtBridge's macro project discovers Swift through PATH independently of this build.
get_filename_component(INZONE_SWIFT_DIRECTORY "${CMAKE_Swift_COMPILER}" DIRECTORY)
set(ENV{PATH} "${INZONE_SWIFT_DIRECTORY}:$ENV{PATH}")
find_program(INZONE_SWIFT_EXECUTABLE swift HINTS "${INZONE_SWIFT_DIRECTORY}" REQUIRED NO_DEFAULT_PATH)

FetchContent_Declare(QtBridge
    GIT_REPOSITORY https://github.com/qt/qtbridge-swift.git
    GIT_TAG 407714006dd21107b70db6547ce75e43df0c8a75
)
FetchContent_MakeAvailable(QtBridge)

add_library(InzoneDBus STATIC Sources/CInzoneDBus/InzoneDBus.c)
target_include_directories(InzoneDBus PUBLIC Sources/CInzoneDBus/include)
target_link_libraries(InzoneDBus PUBLIC PkgConfig::SYSTEMD)

add_library(InzoneGuiRuntime STATIC Sources/CInzoneGuiRuntime/InzoneGuiRuntime.cpp)
target_include_directories(InzoneGuiRuntime PUBLIC Sources/CInzoneGuiRuntime/include)
target_link_libraries(InzoneGuiRuntime PRIVATE Qt6::Core Qt6::Gui Qt6::Quick)
qt_add_resources(InzoneGuiRuntime inzone_icons
    PREFIX "/inzone"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/gui"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/gui/dev.zeroday0619.svg"
)

add_executable(inzone-gui Sources/InzoneGUI/App.swift Sources/InzoneGUI/GuiModel.swift)
target_link_libraries(inzone-gui PRIVATE QtBridge InzoneDBus InzoneGuiRuntime)
target_compile_options(inzone-gui PRIVATE "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>")
set_target_properties(inzone-gui PROPERTIES
    Swift_LANGUAGE_VERSION 6
    Swift_MODULE_NAME InzoneGUI
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

# Keeping the resources outside the executable supports both build-tree and installed launches.
add_custom_target(inzone-gui-resources ALL
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/gui/qml" "${CMAKE_BINARY_DIR}/bin"
)
add_dependencies(inzone-gui inzone-gui-resources)

set(INZONE_SWIFTPM_SCRATCH_PATH "${CMAKE_BINARY_DIR}/swiftpm" CACHE PATH "SwiftPM build directory for the D-Bus service")
set(INZONE_SERVICE_BINARY "${INZONE_SWIFTPM_SCRATCH_PATH}/release/inzone-service")
set(INZONE_SWIFTPM_FLAGS "" CACHE STRING "Additional SwiftPM build arguments")
if(INZONE_DEBIAN_PACKAGE)
    list(APPEND INZONE_SWIFTPM_FLAGS -Xswiftc -use-ld=lld -Xlinker -z -Xlinker relro -Xlinker -z -Xlinker now)
    target_link_options(inzone-gui PRIVATE -use-ld=lld "SHELL:-Xlinker -z -Xlinker relro" "SHELL:-Xlinker -z -Xlinker now")
endif()
file(GLOB_RECURSE INZONE_SERVICE_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/InzoneCore/*.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/InzoneService/*.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/InzoneServiceCore/*.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/CInzoneDBus/*"
)
add_custom_command(OUTPUT "${INZONE_SERVICE_BINARY}"
    COMMAND "${CMAKE_COMMAND}" -E env
        --unset=CC --unset=CXX --unset=LD --unset=AR --unset=CFLAGS --unset=CXXFLAGS --unset=LDFLAGS
        "${INZONE_SWIFT_EXECUTABLE}" build
        --package-path "${CMAKE_CURRENT_SOURCE_DIR}"
        --scratch-path "${INZONE_SWIFTPM_SCRATCH_PATH}"
        --configuration release --product inzone-service --static-swift-stdlib --disable-automatic-resolution ${INZONE_SWIFTPM_FLAGS}
    DEPENDS ${INZONE_SERVICE_SOURCES} Package.swift Package.resolved
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Building the Swift D-Bus service"
    VERBATIM
)
add_custom_target(inzone-service ALL DEPENDS "${INZONE_SERVICE_BINARY}")

set(INZONE_SERVICE_EXECUTABLE "${CMAKE_INSTALL_FULL_BINDIR}/inzone-service")
configure_file(configs/dbus/dev.zeroday0619.service.in
    "${CMAKE_CURRENT_BINARY_DIR}/dev.zeroday0619.service" @ONLY)
configure_file(configs/systemd/inzone-control.service.in
    "${CMAKE_CURRENT_BINARY_DIR}/inzone-control.service" @ONLY)

install(TARGETS inzone-gui RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
install(PROGRAMS "${INZONE_SERVICE_BINARY}" DESTINATION "${CMAKE_INSTALL_BINDIR}")
install(DIRECTORY gui/qml/ DESTINATION "${CMAKE_INSTALL_DATADIR}/inzone-linux/gui")
install(FILES gui/dev.zeroday0619.desktop DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")
install(FILES gui/dev.zeroday0619.svg DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/dev.zeroday0619.service"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/dbus-1/services")
if(INZONE_DEBIAN_PACKAGE)
    set(INZONE_SYSTEMD_USER_DIRECTORY "lib/systemd/user")
else()
    set(INZONE_SYSTEMD_USER_DIRECTORY "${CMAKE_INSTALL_DATADIR}/systemd/user")
endif()
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/inzone-control.service"
    DESTINATION "${INZONE_SYSTEMD_USER_DIRECTORY}")

include(CTest)
option(INZONE_WAYLAND_TESTS "Run native Wayland tests with an isolated KWin compositor" OFF)
set(INZONE_SWAY_EXECUTABLE "" CACHE FILEPATH "Optional Sway executable for isolated Wayland tests")
set(INZONE_HYPRLAND_EXECUTABLE "" CACHE FILEPATH "Optional Hyprland executable for nested Wayland tests")
set(INZONE_GNOME_SHELL_EXECUTABLE "" CACHE FILEPATH "Optional GNOME Shell executable for headless Wayland tests")
set(INZONE_GNOME_TEST_PYTHON "" CACHE FILEPATH "Python interpreter with PyGObject for GNOME tests")
set(INZONE_GNOME_TEST_ENVIRONMENT "" CACHE STRING "Additional environment entries for GNOME test fixtures")
if(BUILD_TESTING)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    find_program(INZONE_DBUS_RUN_SESSION dbus-run-session REQUIRED)
    find_package(Qt6 6.10 REQUIRED COMPONENTS QuickTest Test)
    add_executable(inzone-gui-tests Tests/InzoneGUITests/InputMethodSetup.cpp)
    set_target_properties(inzone-gui-tests PROPERTIES
        AUTOMOC ON
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    )
    target_link_libraries(inzone-gui-tests PRIVATE Qt6::QuickTest Qt6::Test Qt6::Quick Qt6::Qml Qt6::Gui)

    # The integration fixture loads the same C client API used by the Swift GUI.
    add_library(InzoneDBusTestClient SHARED Sources/CInzoneDBus/InzoneDBus.c)
    target_include_directories(InzoneDBusTestClient PRIVATE Sources/CInzoneDBus/include)
    target_link_libraries(InzoneDBusTestClient PRIVATE PkgConfig::SYSTEMD)

    set(INZONE_TEST_HOME "${CMAKE_CURRENT_BINARY_DIR}/test-home")
    file(MAKE_DIRECTORY "${INZONE_TEST_HOME}")
    set(INZONE_QML_TEST_ENVIRONMENT
        "QT_QPA_PLATFORM=offscreen"
        "QT_QUICK_BACKEND=software"
        "HOME=${INZONE_TEST_HOME}"
        "XDG_CONFIG_HOME=${INZONE_TEST_HOME}/.config"
        "XDG_DATA_HOME=${INZONE_TEST_HOME}/.local/share"
    )
    add_test(NAME inzone-gui-smoke
        COMMAND "${INZONE_DBUS_RUN_SESSION}" -- "$<TARGET_FILE:inzone-gui>" --smoke-test)
    set_tests_properties(inzone-gui-smoke PROPERTIES
        ENVIRONMENT "${INZONE_QML_TEST_ENVIRONMENT}"
        TIMEOUT 15
    )

    add_test(NAME inzone-gui-path-launch
        COMMAND "${CMAKE_COMMAND}" -E env "PATH=$<TARGET_FILE_DIR:inzone-gui>:$ENV{PATH}"
            "${INZONE_DBUS_RUN_SESSION}" -- inzone-gui --smoke-test)
    set_tests_properties(inzone-gui-path-launch PROPERTIES
        ENVIRONMENT "${INZONE_QML_TEST_ENVIRONMENT}"
        WORKING_DIRECTORY "${INZONE_TEST_HOME}"
        TIMEOUT 15
    )

    add_test(NAME inzone-gui-interactions
        COMMAND "$<TARGET_FILE:inzone-gui-tests>" -input "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneGUITests")
    set_tests_properties(inzone-gui-interactions PROPERTIES
        ENVIRONMENT "${INZONE_QML_TEST_ENVIRONMENT}"
        TIMEOUT 60
    )

    foreach(INZONE_TEST_SCALE IN ITEMS 1.25 1.5 2)
        add_test(NAME inzone-gui-interactions-scale-${INZONE_TEST_SCALE}
            COMMAND "$<TARGET_FILE:inzone-gui-tests>" -input "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneGUITests")
        set_tests_properties(inzone-gui-interactions-scale-${INZONE_TEST_SCALE} PROPERTIES
            ENVIRONMENT "${INZONE_QML_TEST_ENVIRONMENT};QT_SCALE_FACTOR=${INZONE_TEST_SCALE}"
            TIMEOUT 60
        )
    endforeach()

    if(INZONE_WAYLAND_TESTS)
        find_program(INZONE_KWIN_WAYLAND kwin_wayland REQUIRED)
        find_program(INZONE_KSCREEN_DOCTOR kscreen-doctor REQUIRED)
        find_program(INZONE_QDBUS NAMES qdbus6 qdbus HINTS /usr/lib/qt6/bin REQUIRED)
        foreach(INZONE_WAYLAND_SCALE IN ITEMS 1 1.25 1.5 2)
            add_test(NAME inzone-native-wayland-scale-${INZONE_WAYLAND_SCALE}
                COMMAND "${Python3_EXECUTABLE}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneWaylandTests/native_wayland.py"
                    --dbus-run-session "${INZONE_DBUS_RUN_SESSION}"
                    --compositor "${INZONE_KWIN_WAYLAND}"
                    --output-tool "${INZONE_KSCREEN_DOCTOR}"
                    --qdbus "${INZONE_QDBUS}"
                    --application "$<TARGET_FILE:inzone-gui>"
                    --qmltestrunner "$<TARGET_FILE:inzone-gui-tests>"
                    --qml-tests "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneGUITests"
                    --scale "${INZONE_WAYLAND_SCALE}"
                    --artifacts "${CMAKE_CURRENT_BINARY_DIR}/wayland-validation/scale-${INZONE_WAYLAND_SCALE}")
            set_tests_properties(inzone-native-wayland-scale-${INZONE_WAYLAND_SCALE} PROPERTIES
                TIMEOUT 90
                RUN_SERIAL TRUE
                LABELS "wayland"
            )
        endforeach()
    endif()

    foreach(INZONE_COMPOSITOR IN ITEMS sway hyprland)
        string(TOUPPER "${INZONE_COMPOSITOR}" INZONE_COMPOSITOR_UPPER)
        set(INZONE_COMPOSITOR_EXECUTABLE "${INZONE_${INZONE_COMPOSITOR_UPPER}_EXECUTABLE}")
        if(INZONE_COMPOSITOR_EXECUTABLE)
            if(NOT EXISTS "${INZONE_COMPOSITOR_EXECUTABLE}")
                message(FATAL_ERROR "The requested ${INZONE_COMPOSITOR} test executable does not exist.")
            endif()
            set(INZONE_PARENT_ARGUMENTS)
            if(INZONE_COMPOSITOR STREQUAL "hyprland")
                find_program(INZONE_KWIN_WAYLAND kwin_wayland REQUIRED)
                list(APPEND INZONE_PARENT_ARGUMENTS --parent-compositor "${INZONE_KWIN_WAYLAND}")
            endif()
            foreach(INZONE_COMPOSITOR_SCALE IN ITEMS 1 1.25 1.5 2)
                add_test(NAME inzone-${INZONE_COMPOSITOR}-scale-${INZONE_COMPOSITOR_SCALE}
                    COMMAND "${Python3_EXECUTABLE}"
                        "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneWaylandTests/compositor_session.py"
                        --kind "${INZONE_COMPOSITOR}"
                        --compositor "${INZONE_COMPOSITOR_EXECUTABLE}" ${INZONE_PARENT_ARGUMENTS}
                        --application "$<TARGET_FILE:inzone-gui>"
                        --qmltestrunner "$<TARGET_FILE:inzone-gui-tests>"
                        --qml-tests "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneGUITests"
                        --scale "${INZONE_COMPOSITOR_SCALE}"
                        --artifacts "${CMAKE_CURRENT_BINARY_DIR}/wayland-validation/${INZONE_COMPOSITOR}-${INZONE_COMPOSITOR_SCALE}")
                set_tests_properties(inzone-${INZONE_COMPOSITOR}-scale-${INZONE_COMPOSITOR_SCALE} PROPERTIES
                    TIMEOUT 120 RUN_SERIAL TRUE LABELS "wayland"
                )
            endforeach()
        endif()
    endforeach()

    if(INZONE_GNOME_SHELL_EXECUTABLE)
        if(NOT EXISTS "${INZONE_GNOME_SHELL_EXECUTABLE}")
            message(FATAL_ERROR "The requested GNOME Shell test executable does not exist.")
        endif()
        if(NOT INZONE_GNOME_TEST_PYTHON)
            set(INZONE_GNOME_TEST_PYTHON "${Python3_EXECUTABLE}")
        endif()
        foreach(INZONE_GNOME_SCALE IN ITEMS 1 1.25 1.5 2)
            add_test(NAME inzone-gnome-scale-${INZONE_GNOME_SCALE}
                COMMAND "${INZONE_GNOME_TEST_PYTHON}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneWaylandTests/gnome_session.py"
                    --compositor "${INZONE_GNOME_SHELL_EXECUTABLE}"
                    --application "$<TARGET_FILE:inzone-gui>"
                    --qmltestrunner "$<TARGET_FILE:inzone-gui-tests>"
                    --qml-tests "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneGUITests"
                    --scale "${INZONE_GNOME_SCALE}"
                    --artifacts "${CMAKE_CURRENT_BINARY_DIR}/wayland-validation/gnome-${INZONE_GNOME_SCALE}")
            set_tests_properties(inzone-gnome-scale-${INZONE_GNOME_SCALE} PROPERTIES
                TIMEOUT 120 RUN_SERIAL TRUE LABELS "wayland"
                ENVIRONMENT "${INZONE_GNOME_TEST_ENVIRONMENT}"
            )
        endforeach()
    endif()

    add_test(NAME inzone-dbus-integration
        COMMAND "${INZONE_DBUS_RUN_SESSION}" -- "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/Tests/InzoneServiceTests/Fixtures/session_bus.py"
            "${INZONE_SERVICE_BINARY}" "$<TARGET_FILE:InzoneDBusTestClient>")
    set_tests_properties(inzone-dbus-integration PROPERTIES TIMEOUT 30)
endif()

if(INZONE_DEBIAN_PACKAGE)
    include(cmake/DebianPackaging.cmake)
endif()
