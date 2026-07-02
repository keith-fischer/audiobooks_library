# StoryScripter

Turn an ASCII story `.txt` into a fully voiced audiobook: per-chapter
**character** and **script** files, a **character → voice** mapping, per-chapter
**MP3s**, and a stitched **book MP3** — end to end.

- Scripting (chapters → characters → scripts → voice mapping) is driven by a
  local [LM Studio](https://lmstudio.ai) server (OpenAI-compatible API).
- Audio (script lines → WAVs → per-chapter MP3 → book MP3) is driven by the
  [Voicebox](https://voicebox.sh) desktop app via the `vb/` client.

## Requirements

- Python 3.9+ and `pip install -r requirements.txt`
- **LM Studio** at `http://127.0.0.1:1234` serving a chat model
  (default `qwen3-coder-30b-a3b-instruct`) — needed for the scripting steps.
- **Voicebox** desktop app at `http://127.0.0.1:17493` — needed for audio only.
  `--no-audio` stops before audio and needs neither Voicebox nor ffmpeg.
- **ffmpeg** on `PATH` — to encode chapter MP3s and the book MP3.

## Quick start

Place your story `.txt` in `stories/`, then pass just its file name:

```bash
python main.py "Alice.txt"                 # full pipeline: scripts → voices → audio → book MP3
python main.py "Alice.txt" --no-audio      # stop after scripts + voice mapping
python main.py "Alice.txt" --audio-only    # (re)render audio from existing scripts/mapping
python main.py "Alice.txt" --validate      # validation report only, no processing
python main.py "Alice.txt" --check         # script-vs-chapter fidelity audit, no processing
python main.py "Alice.txt" --force         # reprocess everything, ignore caches
python main.py "Alice.txt" --map           # scripts only, then print the voice_mapper command
```

The name is looked up under `stories/` (the `.txt` is optional, and files in
subfolders are found). A per-story folder `stories/<base>/` is created, the story
is **copied** into it (canonical name, never duplicated), and all output lands
there — the original is never modified.

### All flags

| Flag | Effect |
|------|--------|
| `--model NAME` | override the LM Studio model id |
| `--narrator NAME` | narrator voice (default `Michael`; must exist in `voices_list.txt`) |
| `--no-audio` | stop after scripts + voice mapping (no Voicebox / ffmpeg) |
| `--audio-only` | skip scripting; render + stitch from existing scripts/mapping |
| `--map` | like `--no-audio`, then print the `voice_mapper` GUI command + deep link |
| `--check` | audit existing scripts against their chapters (offline) |
| `--validate` | print the project validation report only |
| `--force` | reprocess everything, ignoring cached chapter/script/MP3 files |
| `--no-vb-restart` | don't auto-restart Voicebox on a connection failure during audio |
| `--no-log` | don't tee console output to `stories/<base>/run_<datetime>.log` |

## The pipeline

1–3. Stage `stories/<base>/` with a copy of the story.
4. Split into chapter text files (novels by `CHAPTER`, plays by `ACT.SCENE`).
5. Extract a character roster per chapter (LLM).
6. Attribute every line to narrator/character → per-chapter script files (LLM).
7. Aggregate into one `<base>_character_mapping.txt`, casting each character to a
   voice from `voices_list.txt` (offline).
8. Render each script line to a WAV via Voicebox.
9. Stitch a chapter's WAVs into `stories/<base>/<base>_<N>.mp3`.
10. Repeat 8–9 **per chapter** — each chapter's MP3 is written before the next
    chapter renders, so you can proof it while the rest run.
11. Once **every** chapter MP3 exists, concatenate them into one book
    `stories/<base>/<base>.mp3` (ffmpeg stream-copy, lossless).
12. Print the pipeline summary + a validation report.

Steps 1–7 are StoryScripter (LM Studio); 8–11 are the `vb/` Voicebox client. Use
`--no-audio` to stop after step 7, or `--audio-only` to run just 8–11.

### Resumable & cache-aware

Re-running picks up from what's already in `stories/<base>/`:

- a **chapter** whose `_characters.txt` + `_script.txt` exist is skipped;
- the **voice mapping** is kept if it exists (manual edits / voice_mapper edits preserved);
- a **chapter MP3** that exists is skipped; WAV rendering is content-addressed
  (named by a hash of voice+text), so only changed lines re-render;
- if validation shows scripting/audio already complete, those stages are skipped
  entirely (so an audio-only top-up doesn't even need the LM Studio server).

Files are written atomically (`.part` → rename). Use `--force` to ignore caches
and rebuild (MP3s are overwritten in place — copy any you want to archive first).

### Audio robustness (Voicebox)

- Each line is **retried** on transient failures, with **repair sweeps** so a
  chapter fully renders in one pass (merge refuses on any missing clip).
- On a connection failure the run **auto-restarts Voicebox**, follows it to
  whatever port it rebinds, waits for `/health`, and resumes — up to two restart
  attempts, then it stops and prints diagnostics. Disable with `--no-vb-restart`.

## Validation report

`--validate` (or the auto-report that runs before/after a normal run when the
project already exists) reconciles, **offline**, what the book implies against
what's on disk, per chapter:

- chapter text / characters / script files exist;
- the expected chapter count matches the book;
- every script line maps to a voice (unmapped speakers flagged);
- the content-addressed WAVs the script implies are all present (and no orphans);
- the chapter MP3 exists.

It prints PASS/FAIL per chapter with the specific issues for fails, plus rollup
`scripting`/`audio` completeness. Exit code is 0 only if the project fully passes.

## Reverse validation (`--check`)

`--check` audits generated scripts against their chapter text — no LLM. For each
`<base>_<label>_script.txt` it reconstructs the spoken text and word-aligns it to
`<base>_<label>.txt` with `difflib`, reporting **coverage** (original words kept),
**fidelity** (script words traceable to the original), and the mismatching spans
(≥4 words; dropped `"…he said"` tags / headings bucketed as expected). A chapter
PASSES at coverage ≥ 90% and fidelity ≥ 90% with no malformed lines; exit code 0
only if all pass, so it works in CI.

## Logging

Every run tees its console output to `stories/<base>/run_<datetime>.log` (stdout
and stderr, with a timestamped header), so the full transcript — scripting
progress, per-line render results, summaries — is saved alongside the project.
Disable with `--no-log`.

## What it produces

For `stories/My Story.txt` with N chapters, in `stories/My Story/`:

| File | Contents |
|------|----------|
| `My Story.txt` | the copied source story (original untouched) |
| `My Story_1.txt` | raw text of chapter 1 |
| `My Story_1_characters.txt` | `name\tgender\tdescription` per line |
| `My Story_1_script.txt` | `{meta}\t{speaker}\t{text}` per line, in story order |
| `My Story_character_mapping.txt` | one row per unique character (see below) |
| `wav/1/<voice>-<hash>.wav` | content-addressed WAV per script line |
| `My Story_1.mp3` | chapter 1 audio |
| `My Story.mp3` | the whole book (all chapters concatenated) |
| `run_<datetime>.log` | console transcript of each run |

- Non-spoken prose is attributed to `narrator`, **one sentence per line** (a
  sentence > 16 words is broken at the next comma).
- Quoted dialogue is attributed to the speaking character (quotes stripped).
- **Every script line is capped at 25 words** (Voicebox degrades on long
  speeches): lines over 25 words are split into consecutive same-speaker lines —
  first at a comma past the 16th word, then hard-split at 25 — and the chapter
  script file is rewritten in place. This runs before audio on every processing
  run, so it repairs existing scripts too.

## Character → voice mapping

After scripting, the per-chapter character files are aggregated into
`My Story_character_mapping.txt` — one row per unique character:

```
{voice_meta}\t{character}\t{voice}\t{gender}\t{description}
```

- **voice** is a Name from `voices_list.txt`, gender-matched and assigned by the
  `PRIORITY` column: `0` voices are never used; `1` first (random order), then
  `2`, `3`, …; unique-first, so a voice is **reused only once that gender's pool
  is exhausted**. The **narrator** is the first row (default `Michael`). Offline.
- **gender** keeps the `*male`/`*female` guess marker (explicit beats guessed).
- **description** concatenates each chapter's description, prefixed by its label.
- **speaking parts only** — in each `_characters.txt`, a character with no
  speaking line in that chapter is prefixed with `*` on its **name** (e.g.
  `*van der Berg`, referenced but silent). Aggregation skips `*` rows, so a
  character is mapped only if it speaks in at least one chapter; one that is `*`
  everywhere is omitted from the mapping.

### voice_mapper — pick voices interactively

`voice_mapper/` is a small local web GUI (started manually) to audition voices
and assign them per character, then save the mapping — a checkpoint between
scripting and audio:

```bash
./run_voice_mapper.sh            # start the GUI at http://127.0.0.1:5005
./run_voice_mapper.sh Alice      # start + open straight to that story
```

Pick a story folder (must have chapter scripts), hear any voice on demand (played
in your browser), assign one per character, and **Save** to the project's mapping
file. A second panel reconciles `voices_list.txt` against the live Voicebox voice
list (matched / file-only / Voicebox-only) and exports an edited copy. See
[`voice_mapper/README.md`](voice_mapper/README.md). Typical flow:

```bash
python main.py "Alice.txt" --no-audio     # build scripts + initial mapping
./run_voice_mapper.sh Alice               # audition + assign voices, Save
python main.py "Alice.txt" --audio-only   # render audio with the chosen voices
```

## Batch processing

`run_batch.sh` runs the pipeline on every `stories/*.txt` that doesn't yet have a
`stories/<base>/` folder (safe to re-run; extra args pass through to `main.py`):

```bash
./run_batch.sh                 # full pipeline on each unprocessed story
./run_batch.sh --no-audio      # scripts/mapping only
```

## Chapters vs. plays

Splitting is algorithmic and format-aware (Project Gutenberg boilerplate and any
table-of-contents are stripped first):

- **Novels** split on `CHAPTER` headings — `Chapter 1 - Title`, `CHAPTER I.`,
  `CHAPTER XII` (Arabic/Roman) and word forms `CHAPTER ONE` … `CHAPTER
  TWENTY-THREE`. Also `Chapt`/`Chap`/`Ch.` variants. Label = chapter number.
- **Bare-number / heading chapters** — ebooks that mark chapters as a lone
  number line + short title (`2` ⏎ `First Sight`), or a bare Roman-numeral /
  cardinal-word line (`III`, `ONE`), with no "CHAPTER" word, are detected too —
  but only when no `CHAPTER` headings exist and the values form a clean
  `1,2,3,…` run (so stray page numbers can't over-split).
- **Plays** split on `ACT` + `SCENE` headings — modern (`ACT I`, `SCENE II`) or
  First Folio Latin (`Actus Primus`, `Scoena Prima`). Label is `act.scene`, so
  **ACT I SCENE 1 → `1.1`** (`Romeo and Juliet_1.1.txt`); acts with no scene
  markers fall back to act-only labels.
- **Blank-gap fallback** — a book that separates chapters only with a big blank
  gap (more than 3 blank lines) and no heading is split on those gaps, but only
  when they carve it into ≥3 sizeable segments; otherwise (continuous prose) it
  stays one chapter.

Detection is a pipeline tried most-obvious first (`Chapter N` → bare-number+title
→ `ACT`/`SCENE` → blank-gap → single); the first pattern that matches is the
book's chapter method. If a large book still yields a single chapter, the LLM is
asked to sanity-check and a warning is printed (it never changes the split).
A story with no detectable pattern is one chapter `1`.

> A text can only be split where it marks divisions: the bundled First Folio
> *Romeo and Juliet* labels only `Actus Primus. Scoena Prima.`, so it yields a
> single `1.1` segment. Audio (steps 8–11) processes integer-numbered chapters;
> plays produce scripts/mapping but no per-chapter MP3s.

## Layout

- `llm_client.py` — `LLMClient`: LM Studio wrapper (`chat`, `test_connection`)
- `story_scripter.py` — `StoryScripter(LLMClient)`: scripting pipeline
- `main.py` — CLI entry point (scripting + audio + validation + logging)
- `vb/` — Voicebox client: render WAVs, stitch MP3s, play (see `vb/README.md`)
- `voice_mapper/` — local web GUI for voice assignment (see its README)
- `voices_list.txt` — voice reference: `NAME, GENDER, PRIORITY, LANG, VOICE ID, MODEL`
- `run_story_voice_scripter.sh`, `run_batch.sh`, `run_voice_mapper.sh` — convenience launchers
