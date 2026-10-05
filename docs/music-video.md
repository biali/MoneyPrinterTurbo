# Music videos from an existing song

`POST /api/v1/music_videos` renders a stock-footage video for a song you already have,
for example one made by [PersonalDJ](https://github.com/biali/PersonalDJ). The song is
the only audio track: there is no TTS, and background music is turned off.

## Request

This is a multipart form with three fields:

| Field | Required | Content |
|---|---|---|
| `audio` | yes | The song: mp3, wav, flac, m4a, aac, ogg or opus, up to 200 MB. |
| `subtitle` | no | An SRT of the synced lyrics, up to 2 MB. It is burned in exactly as sent. |
| `params` | yes | A JSON `TaskVideoRequest`, the same model `POST /videos` uses. |

Useful `params` for a music video:

- `video_subject`: the song title. Required.
- `video_script`: the lyrics. Setting it stops the LLM from writing a script.
- `video_terms`: stock-footage search terms. Setting it stops the LLM from generating terms.
- `video_aspect`: `"16:9"` for YouTube.
- `match_materials_to_script`: `true` makes clips follow the order of `video_terms`.
- `subtitle_provider`: a per-request override of `[app].subtitle_provider`.
  - Without a `subtitle` file, `"whisper"` transcribes the song and then replaces each line's text with the matching line of `video_script`.
  - `""` disables subtitles.

The endpoint always sets `bgm_type=""` and `voice_volume=1.0`. The uploads are stored in
`storage/tasks/<task_id>/` as `song.<ext>` and `lyrics.srt`.

```bash
curl -F audio=@song.mp3 -F subtitle=@song.srt \
  -F 'params={"video_subject":"My Song","video_script":"...","video_terms":["ocean waves","city night"],"video_aspect":"16:9","match_materials_to_script":true}' \
  http://localhost:8080/api/v1/music_videos
```

The response is the same as for `POST /videos`: `data.task_id`. Poll
`GET /api/v1/tasks/<task_id>` until `state` is `1` (complete) or `-1` (failed). The finished
video is `data.videos[0]`.

## Fields added to `VideoParams`

- `custom_subtitle_file`: an SRT to use instead of generating subtitles. It is resolved the
  same way as `custom_audio_file`: first inside the task directory, then as an existing
  server path. If the file is missing or has no valid cues, the task fails at the `subtitle`
  stage.
- `subtitle_provider`: when set, it overrides `config.app.subtitle_provider` for this task.

## Notes

- Stock footage needs `pexels_api_keys` or `pixabay_api_keys` in `config.toml`.
- Whisper timing uses the `[whisper]` model. `large-v3` on a CPU is slow for a 3-minute
  song. Consider `model_size = "medium"` or a GPU device.
