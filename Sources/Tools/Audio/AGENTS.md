# Audio tool instructions

Audio tools provide trimming, normalization, channel conversion, bleeping, and visualizer workflows. Use native AVFoundation paths where implemented and FFmpeg only where required. Validate time ranges and tracks, propagate cancellation, and avoid leaking audio content in logs. Test no-track, short-duration, and missing-FFmpeg cases.
