Building
========

Prerequisites
-------------
* Xcode 5 or later.
* Requires that a pre-built copy of VLCKit.framework v2.1 or later is placed in this folder. I'm using [2.1-stable](http://git.videolan.org/gitweb.cgi?p=vlc-bindings/VLCKit.git;a=shortlog;h=refs/heads/2.1-stable) with some patches backported from version 2.2, and with plugins taken from VLC.app 2.14. If you don't want to build your own version of VLCKit you can extract my version from the QLVideo binaries.

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
* The QuickLook and Spotlight daemons spawn helper processes (QuickLookSatellite and mdworker) to do the actual thumbnailing/indexing. These helpers often perform several thumbnailing/indexing operations concurrently. This is good because it means that the significant load-time costs of initialising libvlc are amortised across several media files. However it means that both plugins need to be multithreading safe.
* VLCKit, libvlc and/or codecs can sometimes crash on corrupt or incompletely downloaded media files. In Release builds both plugins install exception handlers which quietly kill the worker process so that the user isn't disturbed by crash reports. This is an ugly hack.
