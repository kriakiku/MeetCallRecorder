# MeetCallRecorder

A tiny macOS menu bar app that automatically records Google Meet calls and
Slack huddles - just the call window's video and that app's own audio, not
the whole screen or system audio. Finished recordings are left in
`~/Movies/MeetCallRecorder`.

## How it works

- **Detection**: polls `CGWindowListCopyWindowInfo` every 8s for a window
  owned by "Google Meet" titled `Meet: ...`, or by "Slack" titled
  containing "Huddle". Needs `.optionAll` rather than `.optionOnScreenOnly`
  - an occluded call window (the normal case when recording in the
  background) is still "on screen" in Quartz's terms but silently dropped
  by the on-screen-only option.
- **Recording**: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
  with a `desktopIndependentWindow` content filter - captures that one
  window's video regardless of occlusion/focus, and (confirmed
  empirically: a sound played from an unrelated process during a test
  capture did not appear in the recording) scopes audio to that window's
  owning app, not the whole system. No OBS, no virtual audio driver.
- **Compositing**: every frame is redrawn onto a fixed 1920x1080@30fps
  canvas (`FrameComposer`) - the system desktop wallpaper as background,
  the window scaled (preserving aspect ratio) to fit a centered 32px safe
  area, regardless of the call window's actual size. Needs
  `SCStreamConfiguration.shouldBeOpaque = false` on the source capture, or
  the window's rounded corners/shadow come through as opaque black instead
  of transparent.
- **Identity**: each call gets an identifier (`recUdra-JmfQ4j9F` - the
  prefix plus 8 alphanumerics; a UUID style exists in `RecordingID` for a
  future setting), generated when its folder is created, stored in
  `call.json` so it survives a restart mid-call, and stamped translucently
  into the bottom-right of every plate, inside the safe-area margin the
  window content can never reach. Text drawn over the picture - plate
  titles, captions, the identifier - shares one treatment: faint white
  with a dark outline under a soft shadow, since the corner it lands in
  may well be a bright patch of wallpaper.
- **Output**: fragmented QuickTime (`AVAssetWriter.movieFragmentInterval`)
  written into a per-call folder under `~/Movies/MeetCallRecorder/staging/` -
  QuickTime and not fragmented MP4, because the hardware H.264 encoder
  under a fragmented *MP4* writer fails intermittently on macOS 26 with
  -11800/-16341 (reproduced with generated frames and no capture at all:
  4 of 5 synthetic runs died within seconds; the same writer as fragmented
  QuickTime passed every run, as did 120s of real window capture that
  previously broke up every 2-10s) -
  periodically closes out a playable chunk, so a crash mid-recording loses
  at most the last second (confirmed: a `kill -9` mid-recording left a
  valid, playable file up to the last fragment boundary). Staged segments
  are encoded above the final bitrate, since they get re-encoded once
  during assembly and a source at the target rate loses more in that pass.
  `staging/` itself is hidden, excluded from Time Machine, and marked
  `.metadata_never_index` - nothing in it is a finished recording, so none
  of it belongs backed up or searched. All of assembly's own scratch work
  (remuxed segments, the silent video pass, generated silence, the audio
  mux) happens inside the call's own folder there too, and only the
  finished file is ever moved into the recordings folder proper - so a
  failed or interrupted assembly leaves its debris with the call it
  belongs to instead of littering the folder the user actually looks in.
- **Plates drawn on assembly, not on capture**: the recorder writes the
  call and nothing else, logging what happened - welcome, pauses, resizes -
  to `events.jsonl` beside the segments. `RecordingAssembler` reads the
  whole call at finalization and draws the plates then. Live compositing
  could only ever react: a resize isn't known to have ended until after it
  has, so its detection lag and the "has it held still?" wait got baked
  into the picture. Assembly knows both ends of every event before it
  draws anything. The welcome/pause/closing plates insert their own time,
  so nothing of the call is hidden under one.
- **The resize plate is the exception that covers rather than inserts.**
  A window being dragged to a new size is captured at its old, now-stale
  dimensions and stretched to fit, and that is the one stretch of picture
  worth hiding - but only the picture. The plate replaces the frames from
  the moment before the drag was first noticed until it settles, adding no
  time, so the audio underneath is neither cut nor shifted: someone
  talking through a window drag is still heard, and the clock keeps
  running, so the picture that comes back is where the call actually is
  rather than a rewind. It is an ordinary centered card like the others;
  it used to be a badge floating over a blur masked to the window's own
  silhouette, which needed the staged video to keep that silhouette's
  alpha, and reads no better for it.
- **The finished file is HEVC in MP4** (`hvc1`, which AVAssetWriter writes
  and QuickTime requires - `hev1` it won't open): roughly H.264 quality at
  ~60% of the bitrate, native QuickTime/Preview playback (hardware decode
  on any Mac since 2017), plays in Safari/Chrome/Edge - Firefox is the one
  holdout. WebM (VP9+Opus) was tried and rolled back: nothing native opens
  it, and the software VP9 encode took minutes per call where HEVC is the
  same hardware-encoder pass the assembler already does, with every ffmpeg
  pass after it a stream copy.
- **Container metadata**: the finished file carries `recorder_app`,
  `source_app`, `meeting_id` and `recording_id` as plain QuickTime/MP4
  metadata tags, plus `overlays` - a JSON array of every welcome/pause/
  resize/closing plate's `{type, start, end}` on the *output* timeline, in
  seconds, for cutting them out later without having to re-detect them
  from the picture. All of it goes through `ffprobe -show_entries
  format_tags`. Needs `-movflags use_metadata_tags` on every ffmpeg pass
  that touches the file: without it, the mov/mp4 muxer keeps a small fixed
  set of well-known keys (title, comment, artist, ...) and silently drops
  anything else, which only showed up by checking a real mux rather than
  assuming the flag was unnecessary.
- **The closing plate reports the meeting's own span, not the footage
  total.** A sum of segment durations skips straight over every pause -
  nothing was captured during one - but the time still passed, so it's
  added back in from the pause events' own recorded `gap`. The welcome and
  closing plates' own time is the one thing deliberately left out, since
  that's ours, not the meeting's.
- **Call lifecycle**: a call stays open, and resumable, for 90s after its
  window was last seen, so rejoining - or bouncing to another call and
  back - appends another segment to the same folder instead of splitting
  the call across files. A call accumulates extra segments whenever its
  writer has to be replaced mid-call (hardware encoder death, an app
  restart, or being suspended for a different call). On finalization every
  segment is remuxed by ffmpeg into something AVFoundation will open - a
  segment abandoned by a failed writer declares no duration and carries
  decode timestamps unrelated to its presentation ones - and the result is
  assembled into one file in `~/Movies/MeetCallRecorder`.
- **Video and audio are assembled separately**, then muxed. Not a
  preference: AVAssetWriter interleaves its tracks, and driving both from
  one sequential loop of awaiting appends deadlocks - the video append
  stops returning because the muxer wants audio, and the audio it wants is
  what the caller would have sent next. Plates make that unavoidable,
  being video with no audio of their own. The identical pass with the
  audio track removed runs to completion, which is how this was pinned
  down. Audio is therefore built by ffmpeg - each segment's track copied,
  silence generated for every stretch a plate occupies - and stays a
  stream copy rather than a decode and re-encode.

## Requirements

- macOS 26+ (AVAssetWriter's input receiver API).
- **Screen Recording** permission (System Settings > Privacy & Security).
  Prompted automatically on first launch/build. `manage.sh build` signs
  with a local self-signed identity (`setup-signing-identity.sh`, created
  once, no sudo) rather than ad-hoc - ad-hoc signing hashes the binary
  content itself as the identity, so TCC would otherwise treat every
  rebuild as a brand new app and silently drop the grant. With a stable
  identity, one grant survives rebuilds.

## Build & run

```sh
Scripts/manage.sh build      # swift build -c release, package .app, sign with the local dev identity
Scripts/manage.sh install    # build + install as a per-login LaunchAgent (RunAtLoad, no KeepAlive - respects manual Quit)
Scripts/manage.sh update     # stop, rebuild, start - use after any code change
Scripts/manage.sh status
Scripts/manage.sh logs       # tail -f ~/Library/Logs/MeetCallRecorder.log
Scripts/manage.sh uninstall
```

First run needs the Screen Recording grant - open the app once from Finder
or `open MeetCallRecorder.app` before relying on the LaunchAgent.

## Status

Menu bar icon (red when recording). Menu: pause/resume detection, force
start/stop on the frontmost window's app, open recordings folder, open
logs, quit.

## Known limitations / not done yet

- Mute-state reading for Meet (so the icon could also show "you're on
  mute") is unexplored - would need to walk Meet's web-content
  accessibility tree (AXUIElement) or run JavaScript in the hosting
  browser/PWA to find the mic button's state. Separate piece of work.
- Detection patterns (`Meet: `, `Huddle`) are based on real window titles
  seen live during actual calls, but only one account/locale's worth -
  may need adjusting.
