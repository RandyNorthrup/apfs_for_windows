# Third-Party Licenses

APFS for Windows includes or links against these third-party components.

## Qt 6

- License: LGPL-3.0-or-later or commercial, depending on distribution terms
- Website: https://www.qt.io/
- Modules used: Core, Gui, Widgets, Network

The release package includes Qt runtime DLLs required to run the manager,
service IPC client paths, and tools.

## WinFsp

- License: GPLv3 with FLOSS exception
- Repository: https://github.com/winfsp/winfsp
- Source for the pinned release: https://github.com/winfsp/winfsp/tree/v2.2
- Notice: WinFsp - Windows File System Proxy, Copyright (C) Bill Zissimopoulos

WinFsp is required for native Explorer mount support. APFS for Windows links to
the WinFsp user-mode filesystem API and loads the WinFsp DLL from the system
WinFsp installation at run time.

WinFsp is not part of the APFS for Windows files. It is the official,
separately installed WinFsp release pinned in `dependencies/winfsp.json`
(WinFsp 2.2.26323, `winfsp-2.2.26323.msi`, published by NAVIMATICS LLC, with a
kernel driver signed by Microsoft Windows Hardware Compatibility Publisher).
`Setup.exe` carries that unmodified official MSI and installs it when WinFsp is
missing. WinFsp keeps its own license, installer, and Apps & Features entry.
The WinFsp license and notice apply to it in that form.

Earlier releases (0.2.0) bundled a modified side-by-side build from
https://github.com/RandyNorthrup/winfsp-apfs. That fork is no longer shipped;
it remains public for a future hard-link contribution to upstream WinFsp.

## Apple LZFSE

- License: BSD-style license
- Source path: `third_party/lzfse`
- Copyright: Copyright (c) 2015-2016, Apple Inc. All rights reserved.

The copied LZFSE/LZVN reference code supports APFS compression read/write paths.
The full license text is preserved in `third_party/lzfse/LICENSE`.
