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
- Notice: WinFsp - Windows File System Proxy, Copyright (C) Bill Zissimopoulos

WinFsp is required for native Explorer mount support. APFS for Windows links to
the WinFsp user-mode filesystem API. Release packages bundle a dedicated
side-by-side build from `https://github.com/RandyNorthrup/winfsp-apfs`, derived from
the upstream repository above. Development builds may use an installed stock
WinFsp SDK/runtime. The WinFsp license and notice apply to both forms.

## Apple LZFSE

- License: BSD-style license
- Source path: `third_party/lzfse`
- Copyright: Copyright (c) 2015-2016, Apple Inc. All rights reserved.

The copied LZFSE/LZVN reference code supports APFS compression read/write paths.
The full license text is preserved in `third_party/lzfse/LICENSE`.
