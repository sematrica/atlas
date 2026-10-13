# OpenZIM libzim 9.8.2 (official macOS build revision 1)

Sematrica uses the maintained OpenZIM reference implementation rather than implementing ZIM parsing. The C++ library is isolated in `Native/ZIMBridge`; the Swift browser depends on `ArticleProvider`.

Upstream: https://github.com/openzim/libzim
Release artifacts: https://download.openzim.org/release/libzim/
Source release: https://download.openzim.org/release/libzim/libzim-9.8.2.tar.xz
Official build recipes: https://github.com/kiwix/kiwix-build
License: GPL-2.0-or-later; see `COPYING`. The official dylib includes its non-system dependencies; redistribution must satisfy the licenses and corresponding-source obligations of libzim and those dependencies. Sematrica has not been packaged for public distribution or assigned a project-wide license in this change.

The universal dylib combines these official artifacts:

| Artifact | SHA-256 |
| --- | --- |
| libzim_macos-arm64-9.8.2-1.tar.gz | 46da5c485d7ba4ad419d55d031c493ce8996e070edaa622203b5e1dde90b2442 |
| libzim_macos-x86_64-9.8.2-1.tar.gz | 55986239e453bd7fdc77f67d1acc006d896662ad63b17c7e345f49e17363bc40 |

`Scripts/prepare-libzim.sh` reproduces the vendored headers and library. Its install name is changed to `@rpath/libzim.9.dylib`. Xcode embeds and signs it in `Sematrica.app/Contents/Frameworks`; tests use a repository-relative runtime search path. No Homebrew installation, external executable, local HTTP server, or runtime download is required to browse ZIMs.

Both upstream slices declare macOS 12 as their minimum OS; Sematrica retains macOS 14 as its application minimum. The universal binary depends dynamically only on Apple's libSystem and libc++.
