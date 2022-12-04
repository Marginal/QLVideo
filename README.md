QuickLook Video
===============

This package allows macOS Finder to display thumbnails, static previews, cover art and metadata for most types of video files.

QuickLook and Spotlight understand a limited number of media files - mostly only MPEG audio and video codecs within MPEG container files. This package adds support for wide range of other codecs and "non-native" media file types, including `.asf`, `.avi`, `.flv`, `.mkv`, `.rm`, `.webm`, `.wmf` etc.

Installation
------------
* Download the `.dmg` file of the [latest release](https://github.com/Marginal/QLVideo/releases/latest).
* Open it.
* Copy the **QuickLook Video** app to your **Applications** folder (or **Applications** → **Utilities** if you prefer).
* Run the app from where you copied it.

Alternatively, if you have [Homebrew](http://brew.sh/) installed:
* Install with:
   ```
   brew install --cask qlvideo
   ```
* Run the **QuickLook Video** app in your **Applications** folder.

You don't need to keep the app open - you just need to run it once to make macOS notice its QuickLook and Spotlight plugins.
* To see thumbnails of video files you may need to relaunch Finder (hold ⌥/option, right-click on the Finder icon in the Dock and choose **Relaunch**) or log out and back in again.
* You may experience high CPU and disk usage for a few minutes after installation while Spotlight re-indexes all of your "non-native" audio and video files.

Screenshots
-----------
![Finder screenshot](img/finder.jpeg) ![Get Info](img/info.jpeg) ![Preview](img/preview.jpeg)

Limitations
-----------
* The QuickLook "Preview" function displays one or more static snapshots of "non-native" video files. You'll need a media player app (e.g. [VLC](http://www.videolan.org/vlc/) or [MPlayerX](http://mplayerx.org/)) to play these files.
* Interlaced content is sometimes not de-interlaced in QuickLook thumbnails and previews.
* Requires macOS 10.13 "High Sierra" or later on a late-2013 or newer Mac.

Uninstall
---------
* Drag the **QuickLook Video** app to the Trash.

Alternatively, if you installed using [Homebrew](http://brew.sh/), uninstall with:
   ```
   brew remove --cask qlvideo
   ```

Troubleshooting
---------------
* See [here](https://github.com/Marginal/QLVideo/wiki/Troubleshooting).

Acknowledgements
----------------
* Uses the [FFmpeg](https://www.ffmpeg.org/about.html) libraries.
* Uses [OneSky](http://www.oneskyapp.com/) for [translation management](https://marginal.oneskyapp.com/collaboration/project/188351).
* Packaged using [dmgbuild](https://pypi.org/project/dmgbuild/).

License
-------
Copyright © 2014-2022 Jonathan Harris.

Licensed under the [GNU Public License (GPL)](http://www.gnu.org/licenses/gpl-2.0.html) version 2 or later.
