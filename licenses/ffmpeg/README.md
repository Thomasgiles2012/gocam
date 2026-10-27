# FFmpeg attribution and corresponding source

This software uses libraries from the FFmpeg project under LGPL version 2.1 or later: https://ffmpeg.org/ and https://ffmpeg.org/legal.html. Their owners and copyright notices are identified in the corresponding source archive.

The exact unmodified source archive, its detached signature, release public key, build commands and LGPL text are included here. Source: [ffmpeg-7.1.5.tar.xz](ffmpeg-7.1.5.tar.xz). These are third-party sources, not TG's application source. No FFmpeg source changes were made.

The libraries are dynamically loaded from app/ beside GoProFullDecoder.dll. You may replace or modify these LGPL libraries, including reverse-engineering/debugging the application as permitted by LGPL and applicable law. Keep their ABI/version interface compatible with the wrapper. There is no runtime signature/hash lock preventing local library replacement. The first-time setup manifest verifies the supplied download; replace libraries after setup for your own use. A modified build's code should be trusted before loading it.

TG's personal-use restriction applies only to the original application, not to FFmpeg or other third-party code. It does not restrict rights granted by LGPL. When publishing an approved binary download, also publish this complete corresponding-source folder alongside it, with a clear source link on the download page.
