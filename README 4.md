# voicebox_poc

A small client for the **[Voicebox](https://voicebox.app)** desktop app's local REST API that turns a
tab-separated "story" script into spoken audio.

The design separates the two jobs cleanly:

- **Voicebox generates the audio** (text → WAV), one file per line.
- **This client owns playback** — it plays the rendered WAVs locally with precise
  timing (pauses between lines, and deliberate *overlap* for voices talking over
  each other), and can export the whole story to a single MP3.

Two modules:

| File | Role |
| --- | --- |
| `vbpoc.py` | Talks to Voicebox: `speak()`, list voices, and **render** a story's TSV → WAV files. |
| `play_story_wav_files.py` | **Playback only** (no Voicebox needed): play a rendered story from disk, or merge it to MP3. |

Helper scripts: `list_voices.sh`, `make_mp3.sh`.

---

## Requirements

- **macOS** (playback falls back to the built-in `afplay`; the preferred mixer is cross-platform).
- **Python 3.14** using the project-root virtualenv at `../.venv` (shared with
  story_scripter). Run the commands below from inside `vb/`.
- **The Voicebox desktop app** running and serving its local API at
  `http://127.0.0.1:17493` — needed only for *generating/rendering* audio, not for playback.
- **`ffmpeg`** (only for MP3 export) — e.g. `brew install ffmpeg`.

### Install the Python dependencies

```bash
# from inside vb/  (uses the shared project-root venv)
../.venv/bin/pip install -r requirements.txt
```

> Stories resolve to the **project-root** `stories/` (e.g. `stories/Alice/`) — the same
> files story_scripter produces — not a `vb/stories/`.

This installs **`sounddevice`** + **`numpy`**, which power the gapless/overlap mixer.
They're optional: if missing, playback falls back to `afplay` (sequential, no
overlap), and rendering needs neither. (No `requirements.txt`? Just
`../.venv/bin/pip install sounddevice numpy`.)

### Check Voicebox is up (for rendering)

The GUI being open does **not** guarantee the API is up — the backend can be down
while the window stays open. Confirm before rendering:

```bash
curl -s http://127.0.0.1:17493/health        # JSON = up;  connection refused = restart the app
```

---

## Quick start

```bash
# 1. See what voices exist (no rendering needed)
./list_voices.sh            # all voices, grouped by model
./list_voices.sh en         # English only

# 2. Render a story's lines to WAVs in stories/<base>/   (needs Voicebox)
../.venv/bin/python vbpoc.py render party

# 3a. Play it from disk (offline, no Voicebox)
../.venv/bin/python play_story_wav_files.py party

# 3b. ...or render + play live in one go (dual mode)
../.venv/bin/python vbpoc.py play party

# 4. Export the whole story to one MP3 (stories/party.mp3)
./make_mp3.sh               # or: ../.venv/bin/python play_story_wav_files.py party --merge
```

---

## Story files (TSV)

A story is a tab-separated file at `stories/<base>.tsv`. Its rendered audio lives
in `stories/<base>/` as content-addressed `Name-<hash>.wav` files.

**Columns (tab-delimited):**

| A — metadata | B — voice | C+ — text |
| --- | --- | --- |
| optional `key=value` (or a bare number = `delay`) | a voice name from `list_voices.sh` | the line to speak (extra tabs are joined with spaces) |

Lines starting with `#` and blank lines are ignored.

**`delay` metadata** controls timing relative to the **previous line's end**:

- *(blank)* → default **0.8s** pause between lines.
- `delay=2` → 2s pause.
- `delay=-3` → start **3s before** the previous line ends, so the voices **overlap**
  (great for arguments/crowds). Overlap requires the `sounddevice` mixer.

Example:

```
	Daniel	It was the longest night of the year.
	Serena	Welcome, gorgeous people!
delay=-1.2	Ryan	You get lost finding the snack table.
delay=2	Fable	Lovely party. Even lovelier mystery.
```

### Caching (render is a sync)

`render party` reconciles `stories/party/` to the TSV by content hash:

- **Insert a line** → only the new line is generated; the rest are reused.
- **Edit a line's text/voice** → that WAV regenerates (old one auto-deleted).
- **Change only `delay`** → no regeneration (timing is applied at playback).
- **Delete a line** → its WAV is removed as an orphan.

Re-running `render` on an unchanged story is near-instant (everything is cached).

---

## Listing voices

```bash
./list_voices.sh            # default: all languages
./list_voices.sh en         # filter to one language
```

Sample output:

```
Voicebox — all voices
=====================

kokoro  (model)   50 voices
NAME	GENDER	PRIORITY	LANG	VOICE ID	MODEL
Ono Anna	female	0	en	Ono_Anna	qwen_custom_voice
Serena	female	0	en	Serena	qwen_custom_voice
Sohee	female	0	en	Sohee	qwen_custom_voice
Vivian	female	0	en	Vivian	qwen_custom_voice
Alice	female	1	en	bf_alice	kokoro
Alloy	female	1	en	af_alloy	kokoro
Alpha	female	1	en	hf_alpha	kokoro
Alpha	female	1	en	jf_alpha	kokoro
Aoede	female	1	en	af_aoede	kokoro
Bella	female	1	en	af_bella	kokoro
Beta	female	1	en	hf_beta	kokoro
Dora	female	1	en	ef_dora	kokoro
Dora	female	1	en	pf_dora	kokoro
Emma	female	1	en	bf_emma	kokoro
Gongitsune	female	1	en	jf_gongitsune	kokoro
Heart	female	1	en	af_heart	kokoro
Isabella	female	1	en	bf_isabella	kokoro
Jessica	female	1	en	af_jessica	kokoro
Kore	female	1	en	af_kore	kokoro
Lily	female	1	en	bf_lily	kokoro
Nezumi	female	1	en	jf_nezumi	kokoro
Nicole	female	1	en	af_nicole	kokoro
Nova	female	1	en	af_nova	kokoro
River	female	1	en	af_river	kokoro
Sara	female	1	en	if_sara	kokoro
Sarah	female	1	en	af_sarah	kokoro
Siwis	female	1	en	ff_siwis	kokoro
Sky	female	1	en	af_sky	kokoro
Tebukuro	female	1	en	jf_tebukuro	kokoro
Xiaobei	female	1	en	zf_xiaobei	kokoro
Xiaoni	female	1	en	zf_xiaoni	kokoro
Xiaoxiao	female	1	en	zf_xiaoxiao	kokoro
Xiaoyi	female	1	en	zf_xiaoyi	kokoro
Aiden	male	0	en	Aiden	qwen_custom_voice
Dylan	male	0	en	Dylan	qwen_custom_voice
Eric	male	0	en	Eric	qwen_custom_voice
Ryan	male	0	en	Ryan	qwen_custom_voice
Uncle Fu	male	0	en	Uncle_Fu	qwen_custom_voice
Adam	male	1	en	am_adam	kokoro
Alex	male	1	en	em_alex	kokoro
Alex	male	1	en	pm_alex	kokoro
Daniel	male	1	en	bm_daniel	kokoro
Echo	male	1	en	am_echo	kokoro
Eric	male	1	en	am_eric	kokoro
Fable	male	1	en	bm_fable	kokoro
Fenrir	male	1	en	am_fenrir	kokoro
George	male	1	en	bm_george	kokoro
Kumo	male	1	en	jm_kumo	kokoro
Lewis	male	1	en	bm_lewis	kokoro
Liam	male	1	en	am_liam	kokoro
Michael	male	1	en	am_michael	kokoro
Nicola	male	1	en	im_nicola	kokoro
Omega	male	1	en	hm_omega	kokoro
Onyx	male	1	en	am_onyx	kokoro
Psi	male	1	en	hm_psi	kokoro
Puck	male	1	en	am_puck	kokoro
Santa	male	1	en	am_santa	kokoro
Santa	male	1	en	em_santa	kokoro
Santa	male	3	en	pm_santa	kokoro

Total: 59 all voices across 2 engines
```

Use the **NAME** column (e.g. `Nova`, `Daniel`) as the voice in column B of a story.
The **VOICE ID** prefix encodes accent/gender for the `kokoro` model — e.g. `af_` =
American female, `bm_` = British male.

---

## Commands reference

| Command | What it does |
| --- | --- |
| `vbpoc.py render <base>` | Generate/sync `stories/<base>/*.wav` from the TSV (needs Voicebox). |
| `vbpoc.py play <base>` | Dual: render in the background and play live as files appear. |
| `vbpoc.py voices [all\|en\|<lang>]` | Report preset voices (default `all`). |
| `play_story_wav_files.py <base>` | Play a rendered story from disk (offline). `--player auto\|sounddevice\|afplay`. |
| `play_story_wav_files.py <base> --merge` | Merge the story's WAVs to one MP3 (`--out PATH`, `--quality N`). |
| `list_voices.sh [all\|en\|<lang>]` | Wrapper for `vbpoc.py voices`. |
| `make_mp3.sh [base]` | Wrapper for `--merge` (default `party`). |

---

## Voicebox API endpoints used

Full docs are at `http://127.0.0.1:17493/docs`. This project uses only this subset:

| Method & path | Used for |
| --- | --- |
| `GET /health` | Check the server/backend is up. |
| `GET /profiles` | Saved voice profiles (names usable by `speak`). |
| `GET /profiles/presets/{engine}` | Preset voice **catalog** per engine — name, gender, language, voice id (powers `list_voices`). |
| `POST /generate` | Render text → audio **without** server playback (the story path). Needs `profile_id` + `engine`. |
| `POST /speak` | One-shot "speak aloud" on the server (used by `speak()` only). |
| `GET /generate/{id}/status` | SSE stream; poll until `completed`/`failed`. |
| `GET /audio/{id}` | Download the rendered WAV. |
| `POST /generate/{id}/cancel` | Cancel a stalled/failed generation. |
| `GET` / `PUT /settings/generation` | Read/disable `autoplay_on_generate` so `/generate` stays silent during rendering. |

**Why `/generate` and not `/speak` for stories:** `/speak` always plays on the
*server* (ignoring the autoplay setting), which collides with our local playback.
`/generate` only renders and respects `autoplay_on_generate` (which `render` turns
off), so the client fully controls timing, ordering, and overlap.

All requests send an `X-Voicebox-Client-Id` header (default `my-script`).
