# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A proof-of-concept client for the **Voicebox** desktop app's local REST API, split into two modules:
- **`vbpoc.py`** — talks to Voicebox: single-shot `speak()`, voice listing, and **rendering** a story's TSV into WAV files.
- **`play_story_wav_files.py`** — **playback only**, no Voicebox dependency: plays a story's rendered WAVs from disk with scheduling/overlap. Importable and runnable standalone (offline).

Python 3.14, no build step / test suite / linter config. Mostly stdlib (`urllib`, `json`, `threading`, `wave`, `hashlib`); third-party deps **`sounddevice`** + **`numpy`** (`../.venv/bin/pip install sounddevice numpy`) power the gapless/overlap mixer and are optional — playback falls back to `afplay` (sequential, no overlap) if they're missing.

## Running

```bash
../.venv/bin/python vbpoc.py render party   # generate stories/party/*.wav (Voicebox)
../.venv/bin/python vbpoc.py play party     # dual: render + play live
../.venv/bin/python play_story_wav_files.py party   # play-only, from disk, offline
```

Run these from inside `vb/`. `vb/` is a subdirectory of the **story_scripter** project
and uses the shared project-root venv (`../.venv`). `STORIES_DIR` resolves to the
**project-root** `stories/` (`../stories`, e.g. `stories/Alice/`), so the character-script
path (`stories/<story>/<story>_character_mapping.txt` + `<story>_<chapter>_script.txt`,
rendered by `script_to_wav.py`) reads exactly the files story_scripter produces.

Both modules are also importable (`vbpoc.speak/render_story/render_and_play/all_voices/getprofiles`, `play_story_wav_files.play_story`).

### Prerequisite: the Voicebox server (for rendering only)

Rendering (`vbpoc.py`) talks to `http://127.0.0.1:17493` (`BASE_URL`); **play-only does not need it**. The Voicebox desktop app (`/Applications/Voicebox.app`) hosts this API. **The GUI app being open does not guarantee the API is up** — the backend can crash (e.g. during model downloads / GPU errors) while the window stays open, leaving nothing bound to the port. Always confirm before debugging client code:

```bash
curl -s http://127.0.0.1:17493/health        # JSON = up; connection refused = restart the app
curl -s http://127.0.0.1:17493/openapi.json   # full API surface (also at /docs)
```

If the API runs on a different port, change `BASE_URL`/`VOICEBOX_URL` at the top of `vbpoc.py`.

## Architecture & non-obvious behavior

The hard-won knowledge is in how the Voicebox API actually behaves, not in the file layout.

**`/speak` is fire-and-forget; synchronous playback is implemented client-side.** `POST /speak` returns immediately with `status: "generating"` and `duration: 0`. `speak()` makes it synchronous by: (1) polling the SSE stream `GET /generate/{id}/status` (lines are `data: {json}`) until `completed`/`failed`, then (2) `time.sleep(duration)` so the call returns only after the audio has played. There is no server-side blocking speak option.

**Two different voice listings — only one is speakable.** `getvoicelist(engine)` hits `GET /profiles/presets/{engine}` (the full preset *catalog*: voice_id/name/gender/language). `getprofiles()` hits `GET /profiles` (saved profiles). **`/speak`'s `profile` argument only resolves saved profiles** — passing a catalog-only name (or its `voice_id`) returns 404. Iterate `getprofiles()`, not `getvoicelist()`, when you intend to actually speak.

**One serial TTS worker; a stalled job blocks everything behind it.** The status SSE stream emits a `generating` heartbeat ~1/s, so a stuck generation streams forever. Guards against this: `_wait_until_complete` enforces a wall-clock `deadline`, and `speak()` calls `_cancel()` (`POST /generate/{id}/cancel`) on `timeout`/`failed`/`unknown` so a dead job doesn't head-of-line block later requests. If the queue is already jammed, cancel the stuck `generating` entries (find them via `GET /history`).

**`speak()` never raises.** It always returns a dict whose `status` is one of `completed | failed | timeout | error | unknown` (with an `error` message). `render_story` and `all_voices` depend on this to keep iterating past bad voices/lines. `getvoicelist`/`getprofiles` likewise return their default (`[]`/`{}`) when the server is unreachable, via `_get_json`.

**Every request sends the `X-Voicebox-Client-Id` header** (`CLIENT_ID`, default `"my-script"`). Voicebox uses this for per-client voice bindings.

## Stories: render vs play (the core architecture)

Generation and playback are deliberately separate. **Voicebox only generates WAVs; the client owns playback.** A story is a TSV at `stories/<base>.tsv`; its rendered audio lives in `stories/<base>/`.

**TSV format** (`_parse_cues` in `play_story_wav_files.py`): tab-delimited, **A = metadata, B = voice name, C onward = text** (joined with spaces). Blank lines and `#` comments ignored; lines without a voice + text are skipped. Column A metadata (`_parse_meta`) is optional `key=value` pairs (`;`/`,` separated, e.g. `delay=2;emphasis=high`); a bare number is shorthand for `delay`. The only key used today is **`delay`** — seconds relative to the previous clip's end at which this line starts (default `DEFAULT_DELAY` = 1.0s). Positive = pause; **negative = overlap** (`delay=-3` starts 3s before the previous clip ends → voices talk over each other). `delay` is NOT part of the audio identity.

**Content-addressed cache.** Each row's WAV is `stories/<base>/<name>-<hash>.wav` where the hash is over `(voice + text)` (`_wav_name`). So the filename is the row's *audio identity*, independent of TSV position. `render_story` reconciles the folder to the TSV: generate any missing checksum, **delete any WAV whose checksum isn't in the current TSV** (orphans; `delete_orphans=True`). Net: insert a row → only it renders; edit a row's text/voice → new file generated + old deleted; change only `delay` → no work; delete a row → its WAV removed. **Play order always follows the TSV, never filenames.**

**Why `/generate`, not `/speak`** (critical, hard-won): `/speak` always speaks aloud on the *server*, ignoring `autoplay_on_generate` — which caused overlapping/out-of-order server playback on top of ours. `_generate_to_wav` uses **`/generate`** (gated by `autoplay_on_generate`, which `render_story` disables), resolving voice name → `profile_id` + `engine` via `_profiles_by_name` (cached `GET /profiles`; `/generate` needs the id + engine, not a name). WAVs are written **atomically** (`out_path + ".part"` → `os.replace`) so a dual-mode player polling the folder never reads a partial file.

**Playback engine** (`play_story_wav_files.py`, no Voicebox dependency): `_MixerPlayer` (sounddevice + numpy) keeps one callback `OutputStream` open and **sums all currently-playing clips** in the callback — that's what enables both gapless and negative-delay overlap. `play_story` schedules each clip's start as `previous_clip_end + delay` via `time.monotonic`, submitting decoded int16 mono samples (`_load_wav_mono`); it waits for all clips to drain before closing. `_AfplayPlayer` is the fallback (`supports_overlap = False`; negative delays don't overlap there). Source WAVs are never deleted by playback.

**Three entry points:**
- `render_story(tsv)` (`vbpoc.py`) — generate/sync the folder; needs Voicebox.
- `play_story(base, wait_for_files=False)` (`play_story_wav_files.py`) — play from disk; offline. `wait_for_files=True` polls for each WAV (used by dual mode).
- `render_and_play(base)` (`vbpoc.py`) — dual: runs `render_story` in a background thread and `play_story(..., wait_for_files=True)`, so playback starts as the first WAV lands and follows the renderer.

**Export to one file** (`play_story_wav_files.py`): `merge_wav_story_to_mp3(base, out_name=None, quality=2)` stitches the story's WAVs into a single MP3 (default `stories/<base>.mp3`) via ffmpeg/libmp3lame. It uses the same offline mix (`_mix_story`) as the scheduler, so the file reproduces playback exactly — default 1s pauses and negative-delay overlaps baked in (duration ≈ scheduled timeline, not a naive concat). It refuses to write if any row's WAV is missing (run `render` first); falls back to a `.wav` if ffmpeg is absent. CLI: `python play_story_wav_files.py party --merge [--out PATH] [--quality N]`.

Audio plays on the machine running the script, not the Voicebox host; the `afplay` fallback is macOS-only. `render_story` restores autoplay in a `finally` (Ctrl-C safe); a hard kill (SIGKILL) can leave autoplay off and a stray `*.part` file (cleaned on the next render).

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
