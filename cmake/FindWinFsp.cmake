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
#]=======================================================================]

set(_winfsp_roots
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
    set(_winfsp_lib_suffix lib lib\\winfsp-x64 lib\\dll)
else()
    set(_winfsp_lib_suffix lib lib\\winfsp-x86 lib\\dll)
endif()

find_library(WinFsp_LIBRARY
    NAMES winfsp-x64 winfsp-x86 winfsp
    PATHS ${_winfsp_roots}
    PATH_SUFFIXES ${_winfsp_lib_suffix}
)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(WinFsp
    REQUIRED_VARS WinFsp_INCLUDE_DIR WinFsp_LIBRARY
)

if(WinFsp_FOUND AND NOT TARGET WinFsp::WinFsp)
    add_library(WinFsp::WinFsp UNKNOWN IMPORTED)
    set_target_properties(WinFsp::WinFsp PROPERTIES
        IMPORTED_LOCATION "${WinFsp_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${WinFsp_INCLUDE_DIR}"
    )
endif()

mark_as_advanced(WinFsp_INCLUDE_DIR WinFsp_LIBRARY)
