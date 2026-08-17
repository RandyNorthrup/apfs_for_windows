#[=======================================================================[.rst:
FindWinFsp
----------

Find the WinFsp native API headers and import library.

Imported targets:

``WinFsp::WinFsp``
  Native WinFsp user-mode filesystem API.

Variables:

``WinFsp_FOUND``
  True when headers and import library are found.

``WinFsp_INCLUDE_DIR``
  Directory containing ``winfsp/winfsp.h``.

``WinFsp_LIBRARY``
  Import library path.

``WinFsp_RUNTIME_DLL``
  User-mode runtime DLL path.
#]=======================================================================]

set(WinFsp_ROOT "" CACHE PATH "Root of one coherent WinFsp SDK/runtime tree")

set(_winfsp_roots
    "${WinFsp_ROOT}"
    "$ENV{ProgramFiles}\\WinFsp"
    "$ENV{ProgramFiles\(x86\)}\\WinFsp"
    "C:\\Program Files\\WinFsp"
    "C:\\Program Files (x86)\\WinFsp"
)

find_path(WinFsp_INCLUDE_DIR
    NAMES winfsp/winfsp.h
    PATHS ${_winfsp_roots}
    PATH_SUFFIXES inc include
)

if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(_winfsp_lib_suffix lib lib\\winfsp-x64 lib\\dll build/VStudio/build/Release)
else()
    set(_winfsp_lib_suffix lib lib\\winfsp-x86 lib\\dll build/VStudio/build/Release)
endif()

find_library(WinFsp_LIBRARY
    NAMES winfsp-x64 winfsp-x86 winfsp
    PATHS ${_winfsp_roots}
    PATH_SUFFIXES ${_winfsp_lib_suffix}
)

if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(_winfsp_runtime_name winfsp-x64.dll)
else()
    set(_winfsp_runtime_name winfsp-x86.dll)
endif()
find_file(WinFsp_RUNTIME_DLL
    NAMES ${_winfsp_runtime_name}
    PATHS ${_winfsp_roots}
    PATH_SUFFIXES bin build/VStudio/build/Release
)

if(WinFsp_ROOT AND WinFsp_INCLUDE_DIR AND WinFsp_LIBRARY AND WinFsp_RUNTIME_DLL)
    file(REAL_PATH "${WinFsp_ROOT}" _winfsp_declared_root)
    file(REAL_PATH "${WinFsp_INCLUDE_DIR}" _winfsp_real_include)
    file(REAL_PATH "${WinFsp_LIBRARY}" _winfsp_real_library)
    file(REAL_PATH "${WinFsp_RUNTIME_DLL}" _winfsp_real_runtime)
    string(TOLOWER "${_winfsp_declared_root}/" _winfsp_root_lower)
    string(TOLOWER "${_winfsp_real_include}/" _winfsp_include_lower)
    string(TOLOWER "${_winfsp_real_library}" _winfsp_library_lower)
    string(TOLOWER "${_winfsp_real_runtime}" _winfsp_runtime_lower)
    string(FIND "${_winfsp_include_lower}" "${_winfsp_root_lower}" _winfsp_include_prefix)
    string(FIND "${_winfsp_library_lower}" "${_winfsp_root_lower}" _winfsp_library_prefix)
    string(FIND "${_winfsp_runtime_lower}" "${_winfsp_root_lower}" _winfsp_runtime_prefix)
    if(NOT _winfsp_include_prefix EQUAL 0 OR NOT _winfsp_library_prefix EQUAL 0 OR
            NOT _winfsp_runtime_prefix EQUAL 0)
        message(FATAL_ERROR
            "WinFsp headers, library, and runtime must come from WinFsp_ROOT. "
            "Clear cached WinFsp paths and reconfigure.")
    endif()
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(WinFsp
    REQUIRED_VARS WinFsp_INCLUDE_DIR WinFsp_LIBRARY WinFsp_RUNTIME_DLL
)

if(WinFsp_FOUND AND NOT TARGET WinFsp::WinFsp)
    add_library(WinFsp::WinFsp UNKNOWN IMPORTED)
    set_target_properties(WinFsp::WinFsp PROPERTIES
        IMPORTED_LOCATION "${WinFsp_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${WinFsp_INCLUDE_DIR}"
    )
endif()

mark_as_advanced(WinFsp_INCLUDE_DIR WinFsp_LIBRARY WinFsp_RUNTIME_DLL)
