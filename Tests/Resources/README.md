# Test media

`Media/01-h264-aac-baseline.mp4` is the repository's existing baseline video, now copied into test-owned SwiftPM resources so simulator tests do not depend on a checkout path.

`Media/16-h264-subtitle-matrix.mkv` combines that baseline with an original synthetic styled ASS cue and a 16×16 white bitmap encoded as PGS, DVD and DVB subtitle tracks. The PGS display set contains presentation, window, palette, object and end segments, followed by a clear at ten seconds. DVD and DVB streams were encoded from that display set using FFmpeg. It contains no external subtitle text or third-party movie footage.

The subtitle matrix is mandatory. A missing fixture fails setup instead of skipping the interception contract. Native compilation keys exclude these files; candidate test keys include their content digests.
