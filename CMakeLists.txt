cmake_minimum_required(VERSION 3.25)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR "In-source builds are not supported. Use cmake -S . -B build.")
endif()

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" APFS_PROJECT_VERSION LIMIT_COUNT 1)
string(STRIP "${APFS_PROJECT_VERSION}" APFS_PROJECT_VERSION)
if(NOT APFS_PROJECT_VERSION MATCHES "^[0-9]+\.[0-9]+\.[0-9]+$")
    message(FATAL_ERROR "VERSION must contain one semantic version such as 0.1.0.")
endif()

project(apfs_for_windows VERSION ${APFS_PROJECT_VERSION} LANGUAGES C CXX)

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/dependencies/winfsp-apfs.json" APFS_WINFSP_MANIFEST_JSON)
string(JSON APFS_WINFSP_RUNTIME_REPOSITORY GET "${APFS_WINFSP_MANIFEST_JSON}" repository)
string(JSON APFS_WINFSP_RUNTIME_COMMIT GET "${APFS_WINFSP_MANIFEST_JSON}" commit)
find_package(Git REQUIRED)
execute_process(
    COMMAND "${GIT_EXECUTABLE}" -C "${CMAKE_CURRENT_SOURCE_DIR}" rev-parse HEAD
    RESULT_VARIABLE APFS_SOURCE_GIT_RESULT
    OUTPUT_VARIABLE APFS_SOURCE_COMMIT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
execute_process(
    COMMAND "${GIT_EXECUTABLE}" -C "${CMAKE_CURRENT_SOURCE_DIR}" status --porcelain
    RESULT_VARIABLE APFS_SOURCE_STATUS_RESULT
    OUTPUT_VARIABLE APFS_SOURCE_STATUS
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
if(NOT APFS_SOURCE_GIT_RESULT EQUAL 0 OR NOT APFS_SOURCE_STATUS_RESULT EQUAL 0)
    message(FATAL_ERROR "Unable to read source Git provenance.")
endif()
if(APFS_SOURCE_STATUS)
    set(APFS_SOURCE_DIRTY ON)
else()
    set(APFS_SOURCE_DIRTY OFF)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

option(APFS_PRODUCTION_BUILD "Enforce production dependency and compiler gates." OFF)
option(APFS_REQUIRE_WINFSP "Fail configuration when WinFsp is unavailable." OFF)
option(APFS_REQUIRE_NATIVE_HARDLINKS "Require the WinFsp native hard-link ABI." OFF)
option(APFS_WARNINGS_AS_ERRORS "Treat warnings in project-owned targets as errors." OFF)
option(APFS_REPRODUCIBLE_BUILD "Remove source-path and timestamp variance from shipped binaries." OFF)

set(APFS_REPRODUCIBLE_SOURCE_PATH "C:/src/apfs_for_windows")

if(APFS_PRODUCTION_BUILD)
    set(APFS_REQUIRE_WINFSP ON)
    set(APFS_REQUIRE_NATIVE_HARDLINKS ON)
    set(APFS_WARNINGS_AS_ERRORS ON)
    set(APFS_REPRODUCIBLE_BUILD ON)
    if(APFS_SOURCE_DIRTY)
        message(FATAL_ERROR "Production builds require a clean main checkout.")
    endif()
    if(NOT WinFsp_ROOT)
        message(FATAL_ERROR "Production builds require an explicit -DWinFsp_ROOT=<coherent-runtime-root>.")
    endif()
    execute_process(
        COMMAND git -C "${WinFsp_ROOT}" rev-parse HEAD
        RESULT_VARIABLE APFS_WINFSP_GIT_RESULT
        OUTPUT_VARIABLE APFS_WINFSP_CHECKOUT_COMMIT
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
    if(NOT APFS_WINFSP_GIT_RESULT EQUAL 0 OR
            NOT APFS_WINFSP_CHECKOUT_COMMIT STREQUAL APFS_WINFSP_RUNTIME_COMMIT)
        message(FATAL_ERROR
            "Production WinFsp_ROOT must be the pinned winfsp-apfs commit ${APFS_WINFSP_RUNTIME_COMMIT}.")
    endif()
    execute_process(
        COMMAND git -C "${WinFsp_ROOT}" status --porcelain
        RESULT_VARIABLE APFS_WINFSP_STATUS_RESULT
        OUTPUT_VARIABLE APFS_WINFSP_CHECKOUT_STATUS
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
    if(NOT APFS_WINFSP_STATUS_RESULT EQUAL 0 OR APFS_WINFSP_CHECKOUT_STATUS)
        message(FATAL_ERROR "Production WinFsp_ROOT must be a clean checkout.")
    endif()
endif()

function(apfs_apply_project_options target)
    target_compile_definitions(${target} PRIVATE APFS_PROJECT_VERSION="${PROJECT_VERSION}")
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /permissive- /sdl /utf-8 /Zc:__cplusplus /guard:cf)
        if(APFS_REPRODUCIBLE_BUILD)
            if(MSVC_VERSION LESS 1930)
                message(FATAL_ERROR "Reproducible builds require MSVC 19.30 or newer.")
            endif()
            target_compile_options(${target} PRIVATE
                /experimental:deterministic
                /Brepro
                "/pathmap:${CMAKE_SOURCE_DIR}=${APFS_REPRODUCIBLE_SOURCE_PATH}")
        endif()
        if(APFS_WARNINGS_AS_ERRORS)
            target_compile_options(${target} PRIVATE /WX)
        endif()
        get_target_property(target_type ${target} TYPE)
        if(NOT target_type STREQUAL "STATIC_LIBRARY")
            target_link_options(${target} PRIVATE /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA /guard:cf)
            if(APFS_REPRODUCIBLE_BUILD)
                target_link_options(${target} PRIVATE /Brepro)
            endif()
        endif()
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -fstack-protector-strong)
        if(APFS_WARNINGS_AS_ERRORS)
            target_compile_options(${target} PRIVATE -Werror)
        endif()
    endif()
endfunction()

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
apfs_apply_project_options(sak_apfs_core)

if(WIN32)
    target_compile_definitions(sak_apfs_core PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(sak_apfs_core PUBLIC bcrypt)
endif()

add_executable(apfs_probe
    src/tools/apfs_probe.cpp
)

target_link_libraries(apfs_probe PRIVATE sak_apfs_core Qt6::Core)
apfs_apply_project_options(apfs_probe)

add_executable(apfs_mount_service
    src/service/apfs_mount_service.cpp
)
target_link_libraries(apfs_mount_service PRIVATE sak_apfs_core Qt6::Core Qt6::Network)
apfs_apply_project_options(apfs_mount_service)
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
if(APFS_REQUIRE_WINFSP AND NOT WinFsp_FOUND)
    message(FATAL_ERROR "APFS_REQUIRE_WINFSP is enabled, but WinFsp was not found.")
endif()

set(APFS_WINFSP_HAS_NATIVE_HARDLINKS OFF)
if(WinFsp_FOUND)
    set(APFS_WINFSP_HEADER "${WinFsp_INCLUDE_DIR}/winfsp/winfsp.h")
    file(STRINGS "${APFS_WINFSP_HEADER}" APFS_WINFSP_HARDLINK_MACRO
        REGEX "^#define[ \t]+FSP_FILE_SYSTEM_INTERFACE_HAS_CREATE_HARD_LINK[ \t]+1")
    file(STRINGS "${APFS_WINFSP_HEADER}" APFS_WINFSP_HARDLINK_CALLBACK
        REGEX "CreateHardLink")
    if(APFS_WINFSP_HARDLINK_MACRO AND APFS_WINFSP_HARDLINK_CALLBACK)
        set(APFS_WINFSP_HAS_NATIVE_HARDLINKS ON)
    endif()
endif()
if(APFS_REQUIRE_NATIVE_HARDLINKS AND NOT APFS_WINFSP_HAS_NATIVE_HARDLINKS)
    message(FATAL_ERROR "Native hard links require the reviewed dedicated WinFsp runtime.")
endif()
if(APFS_WINFSP_HAS_NATIVE_HARDLINKS)
    target_compile_definitions(apfs_winfs_worker PRIVATE APFS_WINFSP_NATIVE_HARDLINKS=1)
else()
    target_compile_definitions(apfs_winfs_worker PRIVATE APFS_WINFSP_NATIVE_HARDLINKS=0)
endif()
if(APFS_PRODUCTION_BUILD)
    target_compile_definitions(apfs_winfs_worker PRIVATE APFS_PRODUCTION_BUILD=1)
else()
    target_compile_definitions(apfs_winfs_worker PRIVATE APFS_PRODUCTION_BUILD=0)
endif()
if(APFS_SOURCE_DIRTY)
    set(APFS_SOURCE_DIRTY_JSON true)
else()
    set(APFS_SOURCE_DIRTY_JSON false)
endif()
apfs_apply_project_options(apfs_winfs_worker)
if(WIN32)
    target_compile_definitions(apfs_winfs_worker PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(apfs_winfs_worker PRIVATE advapi32)
endif()

add_executable(apfs_mount_manager
    src/manager/apfs_mount_manager.cpp
)
target_link_libraries(apfs_mount_manager PRIVATE Qt6::Core Qt6::Widgets Qt6::Network)
apfs_apply_project_options(apfs_mount_manager)

add_executable(apfs_core_selftest
    src/tests/apfs_core_selftest.cpp
)
target_link_libraries(apfs_core_selftest PRIVATE sak_apfs_core Qt6::Core)
apfs_apply_project_options(apfs_core_selftest)

if(APFS_PRODUCTION_BUILD)
    set(APFS_PRODUCTION_BUILD_JSON true)
else()
    set(APFS_PRODUCTION_BUILD_JSON false)
endif()
if(WinFsp_FOUND)
    set(APFS_WINFSP_FOUND_JSON true)
else()
    set(APFS_WINFSP_FOUND_JSON false)
endif()
if(APFS_WINFSP_HAS_NATIVE_HARDLINKS)
    set(APFS_WINFSP_HARDLINKS_JSON true)
else()
    set(APFS_WINFSP_HARDLINKS_JSON false)
endif()
if(APFS_REPRODUCIBLE_BUILD)
    set(APFS_REPRODUCIBLE_BUILD_JSON true)
else()
    set(APFS_REPRODUCIBLE_BUILD_JSON false)
endif()
file(GENERATE
    OUTPUT "${CMAKE_BINARY_DIR}/$<CONFIG>/apfs-build-metadata.json"
    CONTENT "{\n  \"schema_version\": 4,\n  \"version\": \"${PROJECT_VERSION}\",\n  \"configuration\": \"$<CONFIG>\",\n  \"source_commit\": \"${APFS_SOURCE_COMMIT}\",\n  \"source_dirty\": ${APFS_SOURCE_DIRTY_JSON},\n  \"production_build\": ${APFS_PRODUCTION_BUILD_JSON},\n  \"reproducible_build\": ${APFS_REPRODUCIBLE_BUILD_JSON},\n  \"reproducible_source_path\": \"${APFS_REPRODUCIBLE_SOURCE_PATH}\",\n  \"compiler_id\": \"${CMAKE_CXX_COMPILER_ID}\",\n  \"compiler_version\": \"${CMAKE_CXX_COMPILER_VERSION}\",\n  \"winfsp_found\": ${APFS_WINFSP_FOUND_JSON},\n  \"winfsp_native_hardlinks\": ${APFS_WINFSP_HARDLINKS_JSON},\n  \"winfsp_runtime_repository\": \"${APFS_WINFSP_RUNTIME_REPOSITORY}\",\n  \"winfsp_runtime_commit\": \"${APFS_WINFSP_RUNTIME_COMMIT}\",\n  \"winfsp_header\": \"winfsp/winfsp.h\",\n  \"winfsp_library_name\": \"winfsp-x64.lib\",\n  \"winfsp_runtime_name\": \"winfsp-x64.dll\"\n}\n")

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
add_test(NAME apfs_manager_help COMMAND apfs_mount_manager --help)
add_test(NAME apfs_manager_self_test COMMAND apfs_mount_manager --self-test)
add_test(NAME apfs_core_selftest COMMAND apfs_core_selftest)

set(APFS_TEST_PATH_MODS "PATH=path_list_prepend:${APFS_QT_RUNTIME_DIR}")
list(APPEND APFS_TEST_PATH_MODS "QT_PLUGIN_PATH=set:${APFS_QT_PLUGIN_DIR}")
if(WinFsp_FOUND)
    get_filename_component(APFS_WINFSP_RUNTIME_DIR "${WinFsp_RUNTIME_DLL}" DIRECTORY)
    list(APPEND APFS_TEST_PATH_MODS "PATH=path_list_prepend:${APFS_WINFSP_RUNTIME_DIR}")
endif()

set_tests_properties(apfs_probe_help apfs_worker_status apfs_service_console apfs_service_health apfs_service_control_self_test apfs_service_ipc_self_test apfs_service_log_rotation apfs_service_discovery_empty apfs_service_partition_parser apfs_manager_status apfs_manager_help apfs_manager_self_test apfs_core_selftest PROPERTIES
    ENVIRONMENT_MODIFICATION "${APFS_TEST_PATH_MODS}"
)
