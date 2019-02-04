Building
========

Prerequisites
-------
* Requires Xcode 6.1 and macOS 10.10 SDK or later.
* ffmpeg requires the "yasm" assembler to build. You can obtain it through [Homebrew](https://brew.sh) via `brew install yasm`.

Products
-------
The "QLVideo" scheme in the Xcode project `QLVideo.xcodeproj` builds the following Products:

* ffmpeg - The [FFmpeg](http://ffmpeg.org/) libraries. The plugins depend on these.
* QLVideo.app - Launch Services won't read [Uniform Type Identifiers](http://developer.apple.com/library/mac/documentation/General/Conceptual/DevPedia-CocoaCore/UniformTypeIdentifier.html) from plugin bundles, so this dummy app serves to register the UTIs of the media types that the plugins understand. Should be installed in `/Library/Application Support/QLVideo/`.
* Video.mdimporter - Spotlight plugin. Should be installed in `/Library/Spotlight/`.
* Video.qlgenerator - QuickLook plugin. Should be installed in `/Library/QuickLook/`.

The `resetmds` and `resetquicklood` post-installation scripts can be run to inform Launch Services, SpotLight and QuickLook respectively of any changes.

Debugging
---------
The Spotlight and QuickLook processes cannot be debugged on 10.11 and later due to System Integrity Protection. Copy `mdimport` or `qlmanage` from `/usr/local` to the project directory, and use this copy to debug the plugin.

Packaging
---------
The [Packages](http://s.sudre.free.fr/Software/Packages/about.html) project `QLVideo.pkgproj` packages the above targets into a flat `.pkg` file for distribution. The `.pkg` file includes the post-installation scripts.

Notes
-----
FFmpeg's demuxers and codecs can sometimes crash on corrupt or incompletely downloaded media files. In Release builds both plugins install exception handlers which quietly kill the worker process so that the user isn't disturbed by crash reports. This is an ugly hack.
