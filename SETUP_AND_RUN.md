# Setup & Run

Everything needed to install StoryScripter and run it — every mode, flag, and a
worked example for each. See [`README.md`](README.md) for the conceptual overview
and [`ARCHITECTURE.md`](ARCHITECTURE.md) for how the pieces fit.

---

## 1. What you need

| Piece | Why | Needed for |
|-------|-----|-----------|
| **Python 3.9+** (project venv uses 3.14) | runs the pipeline | everything |
| **ffmpeg** on `PATH` | encodes chapter + book MP3s | audio |
| **LM Studio** at `127.0.0.1:1234` | the LLM that writes characters/scripts | scripting |
| **Voicebox** app at `127.0.0.1:17493` ([repo](https://github.com/jamiepine/voicebox) · [docs](https://docs.voicebox.sh)) | renders the TTS audio | audio + voice preview |

Each is independent per run: `--no-audio` needs only LM Studio; `--audio-only` /
`--validate` / `--check` need no LM Studio; the `voice_mapper` GUI needs only
Voicebox. None are needed to read existing output.

---

## 2. Install

```bash
# from the project root
python3 -m venv .venv                       # one-time: create the virtualenv
.venv/bin/pip install --upgrade pip

# core (scripting): the OpenAI client for LM Studio
.venv/bin/pip install -r requirements.txt

# audio render/playback helpers (numpy/sounddevice; needed for the local mixer)
.venv/bin/pip install -r vb/requirements.txt

# voice_mapper GUI (Flask) — only if you'll use the browser tool
.venv/bin/pip install -r voice_mapper/requirements.txt

# ffmpeg (macOS via Homebrew)
brew install ffmpeg
```

> Examples below use `.venv/bin/python` so you don't have to activate the venv.
> Equivalent: `source .venv/bin/activate` once, then just `python`.

### Confirm the toolchain

```bash
.venv/bin/python --version
ffmpeg -version | head -1
curl -s http://127.0.0.1:1234/v1/models      | head -c 200   # LM Studio up?
curl -s http://127.0.0.1:17493/health                         # Voicebox up?  (JSON = up)
```

---

## 3. Configure the services

### LM Studio (scripting)
1. Install LM Studio, download a chat model — default the pipeline expects is
   **`qwen3-coder-30b-a3b-instruct`** (override with `--model`).
2. Start its **local server** (Developer ▸ Start Server) on port **1234**.
3. `curl -s http://127.0.0.1:1234/v1/models` should list the model.

### Voicebox (audio)

Voicebox is a separate open-source app (Jamie Pine). **The official README and
docs are the authoritative install/run guide — follow them first:**
- Repo & README: <https://github.com/jamiepine/voicebox>
- Docs: <https://docs.voicebox.sh> · Dev setup:
  <https://docs.voicebox.sh/developer/setup>

**Basic install (recommended):** download the prebuilt desktop app for
macOS/Windows/Linux from <https://voicebox.sh> and launch it — that's all this
project needs (it just talks to the local API on **17493**).

**From source (advanced):** per the repo README — `git clone
https://github.com/jamiepine/voicebox`, `just setup`, `just dev` (prereqs: Bun,
Rust, Python 3.11+, Tauri prerequisites, and Xcode on macOS).

Then, regardless of how you installed it:
1. Launch the app (it hosts the API on **17493**).
2. `curl -s http://127.0.0.1:17493/health` → JSON means up. *Connection refused*
   means the backend isn't bound even if the window is open — restart the app
   (the pipeline can also auto-restart it; see `--no-vb-restart`).
3. The voices you can actually render are the app's **saved profiles**. The
   pipeline draws names from `voices_list.txt`; use the `voice_mapper` GUI to
   cross-check the file against the live profiles.

### Voices reference
`voices_list.txt` (project root) is tab-delimited:
`NAME · GENDER · PRIORITY · LANG · VOICE ID · MODEL`. PRIORITY drives casting
(`0` = never used, `1` first, then `2`…). Narrator defaults to **Michael**.

### Your story
Drop an ASCII `.txt` into `stories/`. The pipeline copies it into
`stories/<base>/` and never edits your original.

---

## 4. Quick start

```bash
.venv/bin/python main.py "Alice.txt"
```

Full pipeline: split chapters → characters → scripts → voice mapping → per-chapter
WAVs → per-chapter MP3s → one book `stories/Alice/Alice.mp3` → summary + validation.

### Guided runner — `run_story_voice_scripter.sh`

A wrapper around `main.py` that doubles as a built-in cheat sheet. Run it with **no
story** (or `help` / `-h` / `--help`) to print every parameter and example with
explanations; pass a **story** to forward all arguments straight to `main.py`:

```bash
./run_story_voice_scripter.sh                          # print the full cheat sheet
./run_story_voice_scripter.sh "Alice.txt"              # full pipeline
./run_story_voice_scripter.sh "Alice.txt" --no-audio   # scripts + voice mapping only
./run_story_voice_scripter.sh "Alice.txt" --audio-only --force   # re-render audio
```

Every flag in section 5 works identically through this wrapper. The three
launcher scripts:

| Script | Purpose |
|--------|---------|
| `run_story_voice_scripter.sh [story] [flags]` | guided single-story runner + cheat sheet (forwards to `main.py`) |
| `run_batch.sh [flags]` | process every unprocessed `stories/*.txt` (§7) |
| `run_voice_mapper.sh [story]` | start the voice-mapping GUI (§8) |

> Tip: `./run_story_voice_scripter.sh` with no arguments is the fastest way to see
> the full options/examples in your terminal without opening this file.

---

## 5. `main.py` — every flag

```
python main.py [story] [--model NAME] [--narrator NAME]
               [--no-audio | --audio-only | --map] [--check] [--validate]
               [--force] [--no-vb-restart] [--no-log]
```

| Flag | Meaning | Example |
|------|---------|---------|
| `story` | story file under `stories/` (`.txt` optional; default `Alice.txt`) | `python main.py "Dracula.txt"` |
| `--model NAME` | override the LM Studio model id | `python main.py "Dracula.txt" --model qwen3-coder-30b-a3b-instruct` |
| `--narrator NAME` | narrator voice (default `Michael`; must be in `voices_list.txt`) | `python main.py "Dracula.txt" --narrator George` |
| `--no-audio` | stop after scripts + voice mapping (no Voicebox/ffmpeg) | `python main.py "Dracula.txt" --no-audio` |
| `--audio-only` | skip scripting; render + stitch from existing scripts/mapping | `python main.py "Dracula.txt" --audio-only` |
| `--map` | like `--no-audio`, then print the `voice_mapper` command + deep link | `python main.py "Dracula.txt" --map` |
| `--check` | audit existing scripts vs chapter text (offline; CI-friendly exit code) | `python main.py "Dracula.txt" --check` |
| `--validate` | print the project validation report only (offline) | `python main.py "Dracula.txt" --validate` |
| `--force` | reprocess everything, ignore cached chapter/script/MP3 files | `python main.py "Dracula.txt" --force` |
| `--no-vb-restart` | don't auto-restart Voicebox on a connection failure | `python main.py "Dracula.txt" --audio-only --no-vb-restart` |
| `--no-log` | don't tee output to `stories/<base>/run_<datetime>.log` | `python main.py "Dracula.txt" --no-log` |

Exit codes: `0` success / all-pass; `1` on failure (story not found, LLM down,
scripting failed) or when `--validate`/`--check` find problems.

---

## 6. Run recipes (modes & combinations)

**Full audiobook, from scratch**
```bash
.venv/bin/python main.py "Dracula.txt"
```

**Scripts + voice mapping only (no audio yet)**
```bash
.venv/bin/python main.py "Dracula.txt" --no-audio
```

**Tune voices interactively, then render** (the intended `voice_mapper` flow)
```bash
.venv/bin/python main.py "Dracula.txt" --no-audio     # 1. build scripts + mapping
./run_voice_mapper.sh Dracula                         # 2. audition + assign voices, Save
.venv/bin/python main.py "Dracula.txt" --audio-only   # 3. render with chosen voices
```
`--map` collapses step 1 and prints the step-2 command for you.

**Re-render audio after remapping voices / deleting WAVs**
Because old chapter MP3s are skipped unless forced, use `--force`:
```bash
.venv/bin/python main.py "Dracula.txt" --audio-only --force
```
Each chapter renders then stitches its MP3 immediately (proof it while the next
renders); once all chapters exist, they're concatenated into `Dracula.mp3`.

**Just (re)build the book MP3 from existing chapter MP3s**
```bash
.venv/bin/python main.py "Dracula.txt" --audio-only   # chapters present → render skipped, book stitched
```

**Validate / audit without processing**
```bash
.venv/bin/python main.py "Dracula.txt" --validate     # per-chapter pass/fail, missing WAVs, unmapped speakers
.venv/bin/python main.py "Dracula.txt" --check        # coverage/fidelity of scripts vs source text
```

**Override model and narrator**
```bash
.venv/bin/python main.py "Dracula.txt" --model some-other-model --narrator Lewis
```

**Force a complete rebuild (scripts + audio)**
```bash
.venv/bin/python main.py "Dracula.txt" --force
```

> When the project folder already exists, a **pre-run validation** prints first
> and lets finished stages be skipped; a **post-run validation** prints at the
> end. MP3s are overwritten in place — copy any take you want to keep first.

---

## 7. Batch processing — `run_batch.sh`

Batches the pipeline across many stories **in stages**, controlled by a
**configuration block at the top of the script** (edit the variables). The key
setting is `RUN_MODE`, which both picks the `main.py` stage **and** how stories
are selected — so you can script everything, stop to edit the mappings, then
resume to render audio:

```bash
# ---- in run_batch.sh ----
RUN_MODE=1          # 1 = scripts only (stop before audio)
                    # 2 = audio only (render WAVs + MP3s; run after editing maps)
                    # 3 = full pipeline (scripts + audio, end to end)
MODEL=""            # optional LM Studio model id (blank = default)
NARRATOR="Adam"     # optional narrator voice (blank = Michael)
FORCE=0             # 1 = reprocess ignoring caches
EXTRA_ARGS=()       # any other main.py flags, e.g. (--no-log)
```

| `RUN_MODE` | `main.py` stage | Stories selected | Use it to… |
|------------|-----------------|------------------|-----------|
| `1` | `--no-audio` | **every** story | script new stories + validate/repair existing ones, stop at the voice-mapping checkpoint |
| `2` | `--audio-only` | folders that **have chapter scripts** | render audio **after** editing the mappings (resumable) |
| `3` | *(none)* | **every** story | full end-to-end; validate/repair existing, script+render new |

In every mode `main.py` prints a **validation report per story**, regenerates
only what's missing, and skips what's already complete (complete scripting needs
no LM Studio; complete audio needs no Voicebox) — so any run doubles as a
health-check + repair pass. Mode 1 repair also **adds any new speaking characters
to an existing mapping** (from regenerated chapters) without touching your voice
edits; use `--force` for a clean rebuild (e.g. after chapter detection changes).

The **continue-after-editing workflow:**
```bash
# 1. RUN_MODE=1 — script every new story, stop before audio
./run_batch.sh
#    ... edit each stories/<base>/<base>_character_mapping.txt
#        (by hand, or ./run_voice_mapper.sh <base>) ...
# 2. set RUN_MODE=2 in the script, then re-run to render the audio:
./run_batch.sh
```

Notes:
- Mode 2 is resumable — chapters whose MP3 already exists are skipped. If you
  edit voices for chapters that were **already rendered**, set `FORCE=1` so they
  re-render.
- Any arguments you pass on the command line are appended after the configured
  ones (e.g. `./run_batch.sh --no-log`).
- Prints the mode + a `processed / skipped / failed` tally (exits non-zero if
  any story failed), and after mode 1 reminds you of the next steps.

---

## 8. voice_mapper GUI — `run_voice_mapper.sh`

A local web tool (started manually) to audition voices and assign them per
character, plus reconcile/edit `voices_list.txt`.

```bash
./run_voice_mapper.sh            # start at http://127.0.0.1:5005  (installs Flask if needed)
./run_voice_mapper.sh Dracula    # start + open the browser straight to that story
```

Pick a story folder (must have chapter scripts), hear any voice on demand (plays
in the browser), assign voices, and **Save** to the mapping file. The voices panel
flags **matched / file-only / Voicebox-only** voices and exports an edited
`voices_list.txt` to your Downloads. Stop with Ctrl-C. Details:
[`voice_mapper/README.md`](voice_mapper/README.md).

---

## 9. Advanced — direct `vb/` audio tools

For working with audio outside `main.py` (run from inside `vb/`):

```bash
cd vb

# render one chapter's script to WAVs, or all chapters
../.venv/bin/python script_to_wav.py "Dracula" 5
../.venv/bin/python script_to_wav.py "Dracula" all

# stitch a chapter folder's WAVs to one MP3 (play-only/offline; needs ffmpeg)
../.venv/bin/python play_story_wav_files.py "Dracula" --merge --out out.mp3 --quality 2

# play a rendered story from disk (offline, no Voicebox)
../.venv/bin/python play_story_wav_files.py "Dracula"

# voice utilities (needs Voicebox)
../.venv/bin/python vbpoc.py voices [all|en|<lang>]      # report available voices
../.venv/bin/python vbpoc.py say-voices                  # emotion-capable voices
../.venv/bin/python vbpoc.py say "Michael" "calm" "Hello there." --out sample.wav
```

---

## 10. Outputs & logs

Everything for a story lands in `stories/<base>/` (see `README.md` ▸ *What it
produces*): chapter text, `_characters.txt`, `_script.txt`,
`<base>_character_mapping.txt`, `wav/<N>/…`, `<base>_<N>.mp3`, `<base>.mp3`, and a
`run_<datetime>.log` transcript per run (disable with `--no-log`).

---

## 11. Environment variables

| Var | Default | Effect |
|-----|---------|--------|
| `VOICEBOX_APP` | `Voicebox` | macOS app name used for auto-restart (`open -a` / `pkill`) |

LM Studio / Voicebox addresses are constants in `llm_client.py` (`base_url`) and
`vb/vbpoc.py` (`BASE_URL`) — edit there if your ports differ.

---

## 12. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `aborted: LLM server unavailable` | LM Studio not serving on 1234 — start its server; check `curl :1234/v1/models`. |
| `Voicebox API not reachable` | Voicebox app/backend down — launch it; `curl :17493/health`. The run also tries an auto-restart unless `--no-vb-restart`. |
| Chapters end with `(no mp3) … incomplete` | some lines failed to render — re-run `--audio-only`; per-line retries + repair sweeps fill gaps. Persisting? check Voicebox health. The post-run **ISSUES TO FIX** report lists the exact missing lines. |
| Voicebox fails on a long speech | every script line is auto-capped at 25 words (comma-after-16, then hard-25) and the script file is rewritten before audio; if you'd already rendered long-line MP3s, re-run with `--force` to pick up the split. |
| Audio run skips everything | old chapter MP3s exist — add `--force` to re-render. |
| `book stitch: skipped — N chapter MP3(s) missing` | not all chapters rendered yet; finish them, then the book stitches automatically. |
| `ffmpeg not found` | install ffmpeg (`brew install ffmpeg`); without it MP3s can't be written. |
| `--validate` shows *unmapped* speakers | characters in scripts with no voice in the mapping — assign them in `voice_mapper` or edit `<base>_character_mapping.txt`. |
| Voicebox rebinds a new port | auto-restart re-discovers the port from the live `voicebox-server` process and continues. |
| voice preview silent in GUI | Voicebox down, or the chosen voice isn't a saved profile (shows `file-only` in the reconcile panel). |
