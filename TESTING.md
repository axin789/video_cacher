# Testing checklist

Use this checklist after integrating real test data.

## A. Base setup

- [ ] Flutter version is 3.27.4
- [ ] `flutter pub get` succeeds
- [ ] `flutter analyze` succeeds (main + example)

## B. MP4 flow

- [ ] Enqueue MP4 URL task with `id/name/url`
- [ ] Progress updates as bytes downloaded
- [ ] Pause -> resume works
- [ ] Cancel works and task becomes canceled
- [ ] Completed task has valid `localPath/mp4Path`

## C. HLS flow

- [ ] Enqueue m3u8 URL task
- [ ] Segment progress updates
- [ ] Post-process runs and outputs final mp4
- [ ] Final task status is completed

## D. URL expiration recovery

### D1 MP4
- [ ] MP4 URL expires (404/410) during HEAD -> callback refreshes -> continues
- [ ] MP4 URL expires during stream GET -> callback refreshes -> continues

### D2 HLS
- [ ] Entry m3u8 404/410 -> refreshes and continues
- [ ] Key URL 404/410 -> refreshes and continues
- [ ] TS URL 404/410 -> refreshes and continues

## E. Cancel semantics during remux

- [ ] Start HLS remux
- [ ] Cancel during remux
- [ ] Task status becomes canceled
- [ ] No final output mp4 is produced
- [ ] Temp remux file is cleaned

## F. Album copy

- [ ] `copyToAlbum(taskId)` success path
- [ ] `copyPathToAlbum(path)` success path
- [ ] Permission denied path returns failure cleanly

## G. Persistence

- [ ] Kill app during download and reopen
- [ ] Task restores from SQLite
- [ ] Unfinished task becomes `paused` after reopen
- [ ] User taps continue and resume continues from breakpoint

---

## Test data template

Provide a table like below for validation run:

| caseId | type | id | initialUrl | expected |
|---|---|---|---|---|
| 1 | mp4 | v1001 | ... | normal complete |
| 2 | m3u8 | v1002 | ... | normal complete |
| 3 | mp4-expire | v1003 | ... | refresh and continue |
| 4 | hls-ts-expire | v1004 | ... | refresh and continue |
| 5 | hls-cancel-remux | v1005 | ... | canceled, no final mp4 |
