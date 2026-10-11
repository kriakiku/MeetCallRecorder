# MeetCallRecorder

A tiny macOS menu bar app that automatically records Google Meet calls and
Slack huddles - just the call window's video and that app's own audio, not
the whole screen or system audio - and syncs finished recordings to a
network share for transcription (built for [Speakr](https://github.com/murtaza-nasir/speakr)'s
Black Hole Processing, but the sync target is just a folder).

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
- **Output**: fragmented MP4 (`AVAssetWriter.movieFragmentInterval`) to a
  local staging directory - periodically closes out a playable chunk, so a
  crash mid-recording loses at most the last few seconds (confirmed: a
  `kill -9` mid-recording left a valid, playable file up to the last
  fragment boundary).
- **Sync**: every 2 minutes, while nothing is actively recording, moves
  finished files from staging to the configured network share. Recording
  never targets the share directly - a dropped mount mid-call just delays
  the sync, it can't corrupt or lose the recording.

## Requirements

- macOS 14+.
- **Screen Recording** permission (System Settings > Privacy & Security).
  Prompted automatically on first launch. Ad-hoc code signing means the
  binary's identity changes on every rebuild - if detection silently stops
  working after a rebuild, toggle the permission off/on for
  "MeetCallRecorder" rather than looking for a new prompt (TCC doesn't
  always re-prompt for what looks like the same app).

## Build & run

```sh
Scripts/manage.sh build      # swift build -c release, package .app, ad-hoc sign
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
start/stop on the frontmost window's app, open staging folder, open logs,
quit.

## Known limitations / not done yet

- Mute-state reading for Meet (so the icon could also show "you're on
  mute") is unexplored - would need to walk Meet's web-content
  accessibility tree (AXUIElement) or run JavaScript in the hosting
  browser/PWA to find the mic button's state. Separate piece of work.
- Detection patterns (`Meet: `, `Huddle`) are based on real window titles
  seen live during actual calls, but only one account/locale's worth -
  may need adjusting.
- No retry/backoff tuning on sync failures beyond "try again next pass".
