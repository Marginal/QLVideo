Building
========

Prerequisites
-------
* Requires Xcode 6.1 and macOS 10.13 SDK or later.
* Before building, update submodules with `git submodule update --init --recursive`.
* ffmpeg and its dependencies require "CMake", "pkg-config" and the "yasm" assembler to build. You can obtain them
  through [Homebrew](https://brew.sh) via `brew install cmake pkg-config yasm`.
* Building and packaging require several Python modules. Install these via `pip3 install -r requirements.txt`

Products
-------
The Xcode project `QLVideo.xcodeproj` builds the following Products:

* QuickLook Video.app - App that hosts plugins and registers the
  [Uniform Type Identifiers](http://developer.apple.com/library/mac/documentation/General/Conceptual/DevPedia-CocoaCore/UniformTypeIdentifier.html)
  of the media types that the plugins understand.
* mdimporter - Spotlight plugin provides metadata.
* qlgenerator - QuickLook plugin provides static previews and, on macOS versions prior to Catalina, thumbnails.
* thumbnailer - QuickLook plugin provides thumbnails on macOS Catalina and later.
* benchmark - Simple executable for benchmarking, not included in the app.
* ffmpeg - The [FFmpeg](http://ffmpeg.org/) libraries. The plugins depend on these. Also builds a standalone version of the `ffprobe` executable for bug reporting.
* aom - Support for the [AV1](https://en.wikipedia.org/wiki/AV1) codec. ffmpeg depends on this.

Debugging
---------
All plugins produce output in the system log. Use the filter `subsystem:uk.org.marginal.qlvideo` in the Console app.
* mdimporter - Invoke for debugging with `mdimport -n -d3 <testfile>`
* glgenerator - Invoke for debugging with `qlmanage -p <testfile>`
* thumbnailer - Invoke for debugging with `qlmanage -t -f2 <testfile>`

Notes
-----
FFmpeg's demuxers and codecs can sometimes crash on corrupt or incompletely downloaded media files. In Release builds both plugins install exception handlers which quietly kill the worker process so that the user isn't disturbed by crash reports. This is an ugly hack.
