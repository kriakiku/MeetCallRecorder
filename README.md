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
  Asked for by the welcome screen, not at startup - see below. Nothing
  works without it: ScreenCaptureKit needs it to capture a window, and
  `CGWindowListCopyWindowInfo` needs it to return window *titles*, which
  is how a call is recognised at all. Without the grant every window comes
  back with an empty name and the detector matches nothing, so the app
  looks healthy and records nothing.
- `manage.sh build` signs with a local self-signed identity
  (`setup-signing-identity.sh`, created once, no sudo) rather than ad-hoc
  - ad-hoc signing hashes the binary content itself as the identity, so
  TCC would otherwise treat every rebuild as a brand new app and silently
  drop the grant. With a stable identity, one grant survives rebuilds.

## Welcome screen

First launch - and any later launch where a required grant has gone
missing - opens a two-page setup window instead of going straight to
detection:

1. The app mark, name and what it does.
2. The permissions, each with its own Allow button and live status, plus a
   **Start MeetCallRecorder at login** switch (on by default).

Granting Screen Recording costs one relaunch: macOS only hands a new TCC
grant to a process at launch, so the running copy still can't capture
after the switch is flipped. The screen detects this - a grant that
appeared *during this session* is treated as not-yet-usable - and offers a
Restart button rather than letting Continue through into an app that would
record nothing. The relaunch lands back on page two, not on the greeting.

Reachable any time from the menu bar: **Setup & Permissions…**.

Autostart is the switch on that page, via `SMAppService` - the app appears
under System Settings > General > Login Items and can be turned off there.
It used to be a LaunchAgent plist written by `manage.sh`, which meant the
installer and the app each owned half of the same setting; `manage.sh
migrate` (also run by `install`) removes the leftover plist.

## Settings

**Settings…** in the menu bar, four tabs. Everything persists on change -
there is no apply button. Nothing reaches a recording already in progress:
a call captures its quality and background when it opens, so a change here
takes effect from the next call.

### Quality

720p / 1080p (default) / 1440p / **Audio only**. Bitrate scales with pixel
count off the hand-tuned 1080p pair (12 Mbps staged, 5 Mbps final) - by
area, not by height, or 1440p would come out starved.

Audio only writes `.m4a` and skips the video half of the pipeline
entirely: no canvas, no composer, no screen output registered on the
SCStream, and no plates at assembly. Plates exist to cover a gap in the
*picture*; without one, a pause is just two pieces of audio meeting. That
path is a stream-copy concat and a metadata stamp, so it finishes in well
under a second where the video path takes tens of them.

The quality a call was captured at is written into its staging meta, so a
call recovered after a crash is assembled onto the canvas its segments
actually have, not whatever the setting says by then.

### Capture

**Automatic** watches for call windows, per source - Google Meet and Slack
huddles can be turned off independently. **Manual** (start/stop by hand,
whole main display plus the default microphone) is a stub: the setting is
there and disabled, nothing behind it yet.

Switching to manual, or turning every source off, deliberately does not
stop the poll loop - it only stops it *seeing* anything. The rest of the
loop is what winds an open call down, so a call that was recording at the
moment the setting changed still finalizes through its normal grace
period instead of being stranded in staging.

### Background

What fills the margin around the scaled call window.

1. **Desktop picture** - the default; what the app always did.
2. **Cutting mat** - a drawn blue board with grid, angle guides and edge
   ticks. No network, identical every time.
3. **Random photo** - a different wallhaven.cc wallpaper each call.
4. **Photo per meeting** - the same source, picked from a hash of the
   meeting ID, so one recurring huddle keeps its picture.
5. **Gradient per meeting** - an abstract gradient generated from the
   meeting ID. Stable per meeting, never touches the network.

Resolved once per call before the first segment opens, and awaited - the
composer runs in the sample path, where nothing can wait on a download.

#### Notes on the two generated ones

The gradient is **bezier ribbons**, not stacked radial gradients. A radial
gradient's boundary is a circle, so stacking them can only ever produce
concentric haze; the mesh-gradient look it's chasing is colour regions
meeting along *curves*. Each ribbon is a very wide cubic bezier stroke
that enters and leaves off-canvas (so no round cap is ever visible in
frame), drawn opaque, and then blurred at ~8.5% of the canvas height -
at that radius a stroke edge stops being an edge and becomes the
transition between two colour fields. The first ribbon is deliberately
the widest and routed through the middle, because without that guarantee
some seeds put every curve out past a corner and left the canvas as bare
base gradient.

Hue is the part that took three goes. Clamping everything within ±40° of a
base and blending additively over a near-black floor gave a flat
single-colour wash - the base hue won every time. Opening the spread up
put half the seeds in the amber/yellow-green band, which is brown and
olive at the brightnesses a background behind a call window has to sit at.
The fix after that - giving each hue arc a permitted *direction* to walk -
could not work either, and it's worth saying why: some harmony templates
contained both signs (`[0, 0.11, -0.08]`), so they walked both ways
regardless of what the direction said, which is where the chartreuse rings
and brown smears came from.

What actually holds: the good part of the wheel is treated as **one
contiguous arc** - 0.32 (green) round through teal, blue, violet and
magenta to 1.0 (red) - and every harmony offset is arithmetic *inside*
that arc, reflected at the ends rather than wrapped (wrapping would jump
the short way across the dead zone and land in exactly the olive the arc
exists to avoid). Every resulting hue is then safe by construction: no
per-hue checks, no after-the-fact clamping, and nothing to get wrong when
a new harmony is added. Harmony templates are all one-sided; the side is
picked by the seed and only forced when the widest step wouldn't fit.
Taking the roomier side unconditionally seems safer and isn't - it biases
every palette towards the middle of the arc, which is violet, and two
thirds of the seeds came out purple.

Grain, last: large smooth gradients are the worst case for an 8-bit
encoder and contour visibly without it.

#### Notes on the wallhaven modes

Searches are `categories=100` (general - not anime, not people) and
`purity=100` (SFW), sorted `toplist` over `topRange=1y`, 16x9, at least
1920x1080, against a fixed list of neutral queries.

The API's own `seed` parameter is **not** used for the per-meeting mode.
It looks like it would do the job and doesn't: the server ignores a
client-supplied seed and substitutes one of its own (the same seed sent
twice came back as `qUWuS9` then `gYz5ww`, with different results both
times). Determinism is done locally instead - a hash of the meeting ID
picks a page and an index into the stable `toplist` ordering.

Caching, so this isn't hammering a free API:

- Search result pages are cached for 24 hours.
- Downloaded images are cached by wallpaper ID.
- The resolved meeting → wallpaper ID is pinned in `seed-map.json`, so a
  repeat of a known meeting never calls the API at all. Pinning also makes
  "the same huddle keeps the same picture" survive the listing drifting as
  the year's top wallpapers change.
- Requests are serialized with a minimum gap, well inside the documented
  45/minute.

Everything lives in `~/Library/Caches/MeetCallRecorder/backgrounds/`.
Every failure falls through to the generated gradient rather than
returning nothing, so a recording never silently loses its background
because wallhaven was down.

## Build & run

```sh
Scripts/manage.sh build      # swift build -c release, package .app, sign with the local dev identity
Scripts/manage.sh install    # migrate off the old LaunchAgent, build, start
Scripts/manage.sh update     # stop, rebuild, start - use after any code change
Scripts/manage.sh status     # running? login item registered?
Scripts/manage.sh logs       # tail -f ~/Library/Logs/MeetCallRecorder.log
Scripts/manage.sh uninstall
```

## Status

Menu bar icon (red when recording). Menu: pause/resume detection, force
start/stop on the frontmost window's app, open recordings folder, open
logs, setup & permissions, settings, quit.

## Known limitations / not done yet

- Mute-state reading for Meet (so the icon could also show "you're on
  mute") is unexplored - would need to walk Meet's web-content
  accessibility tree (AXUIElement) or run JavaScript in the hosting
  browser/PWA to find the mic button's state. Separate piece of work.
- Detection patterns (`Meet: `, `Huddle`) are based on real window titles
  seen live during actual calls, but only one account/locale's worth -
  may need adjusting.
