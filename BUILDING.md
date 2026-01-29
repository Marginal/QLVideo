Building
========

Prerequisites
-------
* Requires Xcode with macOS 12 SDK or later.
* Before building, update submodules with `git submodule update --init --recursive`.
* ffmpeg and its dependencies require "Meson", "Ninja", "pkg-config" and the "nasm" assembler to build. You can obtain them
  through [Homebrew](https://brew.sh) via `brew install meson ninja pkg-config nasm`.

Products
-------
The Xcode project `QLVideo.xcodeproj` builds the following Products:

* QuickLook Video.app - App that hosts plugins and extensions, and registers the
  [Uniform Type Identifiers](http://developer.apple.com/library/mac/documentation/General/Conceptual/DevPedia-CocoaCore/UniformTypeIdentifier.html)
  of the media types that the plugins understand.
* mdimporter - Spotlight plugin provides metadata.
* previewer - QuickLook app extension provides previews for non-native file types. Not included in v3 of the app.
* thumbnailer - QuickLook app extension provides thumbnails. Not included in v3 of the app.
* formatreader - App extension that provides support for non-native file types and audio codecs.
* videodecoder - App extension that provides support for non-native video codecs.
* benchmark - Simple executable for benchmarking, not included in the app.
* ffmpeg - The [FFmpeg](http://ffmpeg.org/) libraries. The plugins depend on these. Also builds a standalone version of the `ffprobe` executable for bug reporting.
* dav1d - Support for the [AV1](https://en.wikipedia.org/wiki/AV1) codec. ffmpeg depends on this.
* zimg - Support for format and colour conversion. ffmpeg depends on this.

Debugging
---------
All plugins produce output in the system log. Use the filter `subsystem:marginal.qlvideo` in the Console app.

To debug in Xcode:
* mdimporter - Edit the "Run" scheme for the "mdimporter" target as follows: "Executable": `/usr/bin/mdimport`, "Debug executable": ✔, "Arguments": `-n -d3 <testfile>`.
* previewer - Run the "previewer" target in Xcode. When prompted, choose "Finder" as the app to run. In any Finder window press Space to preview a non-native video file.
* thumbnailer - Doesn't seem possible to debug in Xcode. Good luck!

Notes
-----
FFmpeg's demuxers and codecs can sometimes crash on corrupt or incompletely downloaded media files. In Release builds both plugins install exception handlers which quietly kill the worker process so that the user isn't disturbed by crash reports. This is an ugly hack.
