cmake_minimum_required(VERSION 3.25)

project(apfs_for_windows VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Widgets Network)
get_target_property(APFS_QT_CORE_DLL Qt6::Core IMPORTED_LOCATION_RELEASE)
if(NOT APFS_QT_CORE_DLL)
    get_target_property(APFS_QT_CORE_DLL Qt6::Core IMPORTED_LOCATION)
endif()
get_filename_component(APFS_QT_RUNTIME_DIR "${APFS_QT_CORE_DLL}" DIRECTORY)
get_filename_component(APFS_QT_PREFIX_DIR "${APFS_QT_RUNTIME_DIR}" DIRECTORY)
set(APFS_QT_PLUGIN_DIR "${APFS_QT_PREFIX_DIR}/plugins")

add_library(sak_lzfse STATIC
    third_party/lzfse/src/lzfse_decode.c
    third_party/lzfse/src/lzfse_decode_base.c
    third_party/lzfse/src/lzfse_encode.c
    third_party/lzfse/src/lzfse_encode_base.c
    third_party/lzfse/src/lzfse_fse.c
    third_party/lzfse/src/lzvn_decode_base.c
    third_party/lzfse/src/lzvn_encode_base.c
    third_party/lzfse/sak_lzvn_shim.c
)

target_include_directories(sak_lzfse PUBLIC
    third_party/lzfse/src
)

if(MSVC)
    target_compile_options(sak_lzfse PRIVATE /w)
else()
    target_compile_options(sak_lzfse PRIVATE -w)
endif()

add_library(sak_apfs_core STATIC
    third_party/sak_apfs_core/src/core/apfs_crypto.cpp
    third_party/sak_apfs_core/src/core/apfs_keybag.cpp
    third_party/sak_apfs_core/src/core/partition_apfs_file_system_reader.cpp
    third_party/sak_apfs_core/src/core/partition_apfs_writer.cpp
    third_party/sak_apfs_core/src/core/partition_file_system_detector.cpp
    third_party/sak_apfs_core/src/core/partition_manager_types.cpp
    third_party/sak_apfs_core/src/core/partition_raw_device_io.cpp
)

target_include_directories(sak_apfs_core PUBLIC
    third_party/sak_apfs_core/include
)

target_compile_definitions(sak_apfs_core PRIVATE QT_NO_KEYWORDS)
target_link_libraries(sak_apfs_core PUBLIC Qt6::Core sak_lzfse)

if(WIN32)
    target_compile_definitions(sak_apfs_core PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(sak_apfs_core PUBLIC bcrypt)
endif()

add_executable(apfs_probe
    src/tools/apfs_probe.cpp
)

target_link_libraries(apfs_probe PRIVATE sak_apfs_core Qt6::Core)

add_executable(apfs_mount_service
    src/service/apfs_mount_service.cpp
)
target_link_libraries(apfs_mount_service PRIVATE sak_apfs_core Qt6::Core Qt6::Network)
if(WIN32)
    target_compile_definitions(apfs_mount_service PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(apfs_mount_service PRIVATE advapi32)
endif()

add_executable(apfs_winfs_worker
    src/worker/apfs_winfs_worker.cpp
)
target_link_libraries(apfs_winfs_worker PRIVATE sak_apfs_core Qt6::Core)
find_package(WinFsp QUIET)
if(WinFsp_FOUND)
    target_compile_definitions(apfs_winfs_worker PRIVATE APFS_HAVE_WINFSP=1)
    target_link_libraries(apfs_winfs_worker PRIVATE WinFsp::WinFsp)
else()
    target_compile_definitions(apfs_winfs_worker PRIVATE APFS_HAVE_WINFSP=0)
    message(WARNING "WinFsp SDK not found; apfs_winfs_worker builds in scaffold mode.")
endif()
if(WIN32)
    target_compile_definitions(apfs_winfs_worker PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(apfs_winfs_worker PRIVATE advapi32)
endif()

add_executable(apfs_mount_manager
    src/manager/apfs_mount_manager.cpp
)
target_link_libraries(apfs_mount_manager PRIVATE Qt6::Core Qt6::Widgets Qt6::Network)

add_executable(apfs_core_selftest
    src/tests/apfs_core_selftest.cpp
)
target_link_libraries(apfs_core_selftest PRIVATE sak_apfs_core Qt6::Core)

enable_testing()
add_test(NAME apfs_probe_help COMMAND apfs_probe --help)
add_test(NAME apfs_worker_status COMMAND apfs_winfs_worker --status)
add_test(NAME apfs_service_console COMMAND apfs_mount_service --run-console)
add_test(NAME apfs_service_health COMMAND apfs_mount_service --health)
add_test(NAME apfs_service_control_self_test COMMAND apfs_mount_service --self-test-control)
add_test(NAME apfs_service_ipc_self_test COMMAND apfs_mount_service --self-test-ipc)
add_test(NAME apfs_service_log_rotation COMMAND apfs_mount_service --self-test-log-rotation)
add_test(NAME apfs_service_discovery_empty COMMAND apfs_mount_service --discover-apfs --max-physical-drives 0)
add_test(NAME apfs_service_partition_parser COMMAND apfs_mount_service --self-test-partitions)
add_test(NAME apfs_manager_status COMMAND apfs_mount_manager --status)
add_test(NAME apfs_manager_self_test COMMAND apfs_mount_manager --self-test)
add_test(NAME apfs_core_selftest COMMAND apfs_core_selftest)

set(APFS_TEST_PATH_MODS "PATH=path_list_prepend:${APFS_QT_RUNTIME_DIR}")
list(APPEND APFS_TEST_PATH_MODS "QT_PLUGIN_PATH=set:${APFS_QT_PLUGIN_DIR}")
if(WinFsp_FOUND)
    get_filename_component(APFS_WINFSP_ROOT "${WinFsp_INCLUDE_DIR}" DIRECTORY)
    list(APPEND APFS_TEST_PATH_MODS "PATH=path_list_prepend:${APFS_WINFSP_ROOT}/bin")
endif()

set_tests_properties(apfs_probe_help apfs_worker_status apfs_service_console apfs_service_health apfs_service_control_self_test apfs_service_ipc_self_test apfs_service_log_rotation apfs_service_discovery_empty apfs_service_partition_parser apfs_manager_status apfs_manager_self_test apfs_core_selftest PROPERTIES
    ENVIRONMENT_MODIFICATION "${APFS_TEST_PATH_MODS}"
)
