import json
import os
import shutil
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from app.controllers.v1 import video as video_controller
from app.models.exception import HttpException
from app.models.schema import VideoParams
from app.services import task as tm
from app.utils import utils

SRT = "1\n00:00:01,000 --> 00:00:03,500\nHello from the song\n\n"


class TestCustomSubtitle(unittest.TestCase):
    """A ready-made SRT (synced lyrics) replaces subtitle generation entirely."""

    def setUp(self):
        self.task_id = "test-music-video-subtitle"
        self.task_dir = utils.task_dir(self.task_id)

    def tearDown(self):
        shutil.rmtree(self.task_dir, ignore_errors=True)

    def _params(self, **kwargs):
        return VideoParams(video_subject="song", video_script="Hello", **kwargs)

    def test_custom_subtitle_is_copied_and_skips_providers(self):
        Path(self.task_dir, "lyrics.srt").write_text(SRT, encoding="utf-8")
        with (
            patch.object(tm.subtitle, "create") as whisper_create,
            patch.object(tm.voice, "create_subtitle") as edge_create,
        ):
            subtitle_path = tm.generate_subtitle(
                self.task_id,
                self._params(custom_subtitle_file="lyrics.srt"),
                "Hello",
                sub_maker=None,
                audio_file="song.mp3",
            )

        self.assertEqual(subtitle_path, os.path.join(self.task_dir, "subtitle.srt"))
        self.assertEqual(Path(subtitle_path).read_text(encoding="utf-8"), SRT)
        whisper_create.assert_not_called()
        edge_create.assert_not_called()

    def test_invalid_custom_subtitle_raises(self):
        Path(self.task_dir, "lyrics.srt").write_text("not a subtitle", encoding="utf-8")
        with self.assertRaises(ValueError):
            tm.generate_subtitle(
                self.task_id,
                self._params(custom_subtitle_file="lyrics.srt"),
                "Hello",
                sub_maker=None,
                audio_file="song.mp3",
            )

    def test_missing_custom_subtitle_raises(self):
        with self.assertRaises(ValueError):
            tm.generate_subtitle(
                self.task_id,
                self._params(custom_subtitle_file="nope.srt"),
                "Hello",
                sub_maker=None,
                audio_file="song.mp3",
            )

    def test_request_provider_overrides_config(self):
        def fake_whisper(audio_file, subtitle_file):
            Path(subtitle_file).write_text(SRT, encoding="utf-8")

        with (
            patch.object(tm.config, "app", dict(tm.config.app, subtitle_provider="edge")),
            patch.object(tm.subtitle, "create", side_effect=fake_whisper) as create,
            patch.object(tm.subtitle, "correct") as correct,
        ):
            subtitle_path = tm.generate_subtitle(
                self.task_id,
                self._params(subtitle_provider="whisper"),
                "Hello",
                sub_maker=None,
                audio_file="song.mp3",
            )

        create.assert_called_once()
        correct.assert_called_once_with(subtitle_file=subtitle_path, video_script="Hello")

    def test_empty_request_provider_disables_subtitles(self):
        with patch.object(tm.subtitle, "create") as create:
            subtitle_path = tm.generate_subtitle(
                self.task_id,
                self._params(subtitle_provider=""),
                "Hello",
                sub_maker=None,
                audio_file="song.mp3",
            )
        self.assertEqual(subtitle_path, "")
        create.assert_not_called()


class TestMusicVideoEndpoint(unittest.TestCase):
    """``POST /music_videos`` stores the uploads task-locally and queues a video task."""

    def setUp(self):
        self.storage = tempfile.mkdtemp()
        self.request = SimpleNamespace(headers={"x-task-id": "request-123"})

    def tearDown(self):
        shutil.rmtree(self.storage, ignore_errors=True)

    def _task_dir(self, sub_dir=""):
        path = os.path.join(self.storage, sub_dir)
        os.makedirs(path, exist_ok=True)
        return path

    def _call(self, params, audio, subtitle=None):
        with (
            patch.object(video_controller.utils, "get_uuid", return_value="task-1"),
            patch.object(video_controller.utils, "task_dir", side_effect=self._task_dir),
            patch.object(video_controller.sm.state, "update_task"),
            patch.object(video_controller.task_manager, "add_task") as add_task,
        ):
            response = video_controller.create_music_video(
                self.request, json.dumps(params), audio, subtitle
            )
        return response, add_task

    def test_saves_song_and_lyrics_and_forces_song_audio(self):
        params = {"video_subject": "Song", "bgm_type": "random", "voice_volume": 0.3}
        audio = SimpleNamespace(filename="../My Song.MP3", file=BytesIO(b"audio"))
        subtitle = SimpleNamespace(filename="x.srt", file=BytesIO(SRT.encode()))

        response, add_task = self._call(params, audio, subtitle)

        self.assertEqual(response["data"]["task_id"], "task-1")
        body = add_task.call_args.kwargs["params"]
        self.assertEqual(body.custom_audio_file, "song.mp3")
        self.assertEqual(body.custom_subtitle_file, "lyrics.srt")
        self.assertEqual(body.bgm_type, "")
        self.assertEqual(body.voice_volume, 1.0)
        self.assertEqual(Path(self.storage, "task-1", "song.mp3").read_bytes(), b"audio")
        self.assertEqual(add_task.call_args.kwargs["stop_at"], "video")

    def test_subtitle_is_optional(self):
        audio = SimpleNamespace(filename="a.wav", file=BytesIO(b"audio"))
        _, add_task = self._call({"video_subject": "Song"}, audio)
        self.assertIsNone(add_task.call_args.kwargs["params"].custom_subtitle_file)

    def test_rejects_bad_audio_and_cleans_up(self):
        audio = SimpleNamespace(filename="a.exe", file=BytesIO(b"audio"))
        with self.assertRaises(HttpException) as raised:
            self._call({"video_subject": "Song"}, audio)
        self.assertEqual(raised.exception.status_code, 400)
        self.assertFalse(os.path.exists(os.path.join(self.storage, "task-1")))

    def test_rejects_oversized_subtitle(self):
        audio = SimpleNamespace(filename="a.mp3", file=BytesIO(b"audio"))
        subtitle = SimpleNamespace(filename="x.srt", file=BytesIO(b"x" * 10))
        with patch.object(video_controller, "MUSIC_VIDEO_MAX_SUBTITLE_BYTES", 5):
            with self.assertRaises(HttpException):
                self._call({"video_subject": "Song"}, audio, subtitle)

    def test_rejects_invalid_params(self):
        audio = SimpleNamespace(filename="a.mp3", file=BytesIO(b"audio"))
        with self.assertRaises(HttpException) as raised:
            self._call({"video_aspect": "16:9"}, audio)
        self.assertEqual(raised.exception.status_code, 400)


if __name__ == "__main__":
    unittest.main()
