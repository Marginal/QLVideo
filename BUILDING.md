Building
========

Prerequisites
-------------
* Xcode 5 or later.
* FFmpeg static libraries installed under /usr/local/.

Targets
-------
The Xcode project `QLVideo.xcodeproj` builds the following targets:

* QLVideo.app - Launch Services won't read [Uniform Type Identifiers](http://developer.apple.com/library/mac/documentation/General/Conceptual/DevPedia-CocoaCore/UniformTypeIdentifier.html) from plugin bundles, so this dummy app serves to register the UTIs of the media types that the plugins understand. Should be installed in /Libarary/Application Support/QLVideo/.
* Video.mdimporter - Spotlight plugin. Should be installed in /Library/Spotlight/.
* Video.qlgenerator - QuickLook plugin. Should be installed in /Library/QuickLook/.

The `registerapp`, `resetmds` and `resetquicklood` post-installation scripts can be run to inform Launch Services, SpotLight and QuickLook respectively of any changes.

Packaging
---------
The [Packages](http://s.sudre.free.fr/Software/Packages/about.html) project `QLVideo.pkgproj` packages the above targets into a flat `.pkg` file for distribution. The `.pkg` file includes the post-installation scripts.

Notes
-----
* FFmpeg's demuxers and codecs can sometimes crash on corrupt or incompletely downloaded media files. In Release builds both plugins install exception handlers which quietly kill the worker process so that the user isn't disturbed by crash reports. This is an ugly hack.
* Binary releases of this package are built and tested against a minimal installation of FFmpeg 2.8.3:

`./configure --cc=clang --arch=x86_64 --cpu=core2 --extra-cflags=-mmacosx-version-min=10.9 --extra-ldflags=-mmacosx-version-min=10.9 --enable-gpl --enable-hardcoded-tables --disable-pthreads --disable-indevs --disable-network --disable-avdevice --disable-muxers --disable-encoders --disable-bsfs --disable-filters`
