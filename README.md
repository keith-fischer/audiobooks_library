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
| `--reconcile` | reverse-lookup: reconcile the character mapping against the scripts — per-character line counts, unmapped/silent/mis-starred issues, PASS/FAIL (offline) |
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

- Non-spoken prose is attributed to `narrator`; quoted dialogue is attributed to
  the speaking character (quotes stripped).
- **Script lines are flowed to minimize pauses** (each line = one WAV = one pause
  when stitched): text accumulates into a line until it has ≥16 words **and** hits a
  natural break (`.` `,` `?` `!` or a closing quote), landing near an optimum of
  ~25 words, and is force-broken only at **50 words** if no punctuation is found.
  Terminal punctuation is kept so the pause sounds natural; `Mr.`/initials don't
  trigger a break.
- **`normalize_scripts` reflows in place before audio**, merging short consecutive
  same-speaker lines and re-splitting over-long ones. It's offline, idempotent, and
  repairs existing scripts without re-running the LLM.

## Character → voice mapping

After scripting, the per-chapter character files are aggregated into
`My Story_character_mapping.txt` — one row per unique character:

```
{voice_meta}\t{character}\t{voice}\t{gender}\t{description}
```

- **voice** is a Name from `voices_list.txt`, gender-matched and assigned by the
  `PRIORITY` column: `0` voices are never used; `1` first (random order), then
  `2`, `3`, …; **most-spoken characters get unique voices first**. The **narrator's
  voice is reserved** and never assigned to a character; once a gender's pool is
  fully allocated, remaining characters **reuse a duplicate** (least-spoken first).
  The **narrator** is the first row (default `Michael`). Offline.
- **voices for unmapped speakers** — before audio, any script speaker with no voice
  in the mapping is assigned a **real gender-matched voice** (unique if free, else a
  duplicate — never the narrator), so no lines are silently dropped. `*`-starred
  non-speakers stay silent. (The renderer only narrates a speaker as an absolute
  last resort when it has no voice at all.)
- **gender** keeps the `*male`/`*female` guess marker (explicit beats guessed).
- **description** concatenates each chapter's description, prefixed by its label.
- **full roster, speakers un-starred** — every character is kept in the mapping
  (so the cast stays complete), but the `*` name prefix marks non-speakers. A
  character that has a real dialogue line in **any** chapter script is a speaker:
  unstarred, gets a voice/WAV. A character that never speaks in any chapter script
  (referenced-only, e.g. `*van der Berg`) keeps its `*` and description but gets no
  voice/WAV. In each `_characters.txt` a per-chapter non-speaker is `*`-prefixed;
  the scripts are authoritative, so a roster character mismarked `*` is
  force-unstarred if a script actually attributes a line to it. The **narrator** is
  never starred; `*` is reversible by editing the file or in voice_mapper.
- **optional book cross-check** — `validate_character_mapping_file_with_story` can
  additionally star mapped characters with no *quoted dialogue in the original book*
  (groups/collectives/disembodied voices like `The ladies`, `Voice from the grave`).
  It is **not** applied automatically (it can false-flag real script speakers); run
  it manually via `_run_speaker_cleanup()` when you want the stricter pass.

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

## The voice cast 🎙️

StoryScripter ships with a **59-voice ensemble** spanning two TTS engines — a
full casting room of narrators, heroes, villains and scene-stealers, all served
locally by Voicebox. No cloud, no API keys, no per-character fees: every voice
below renders on your own machine, and thanks to content-addressed caching each
line is only ever synthesized once.

### Qwen CustomVoice — the multilingual character actors (9 voices)

These are the show-offs of the roster. Each Qwen CustomVoice speaks **ten
languages with the same voice** — hand one of them a line with embedded Spanish
(`"Hola, señora"`) and it pronounces it like a native *without changing who's
talking*. They're also the only voices with **emotion direction**: pass an
`instruct` prompt ("furious, shouting", "soft and wistful") and the delivery
follows.

| Voice | Gender | Superpowers |
|-------|--------|-------------|
| Serena | female | warm lead voice, emotion-directable, 10-language code-switching |
| Vivian | female | bright and expressive, emotion-directable |
| Sohee | female | smooth storyteller tone, great for dialogue |
| Ono Anna | female | light, youthful character voice |
| Ryan | male | confident all-rounder — a natural narrator |
| Aiden | male | younger energy, good for protagonists |
| Dylan | male | relaxed, conversational |
| Eric | male | grounded and steady |
| Uncle Fu | male | gravel and gravitas — instant elder/mentor casting |

### Kokoro — the 50-voice repertory company

Fast, light, and *huge*: fifty preset voices — and **every single one of them
reads English**. The American and British voices are native English speakers;
the international voices read English with their authentic accent, still
perfectly clear and easy to follow. That's not a limitation, it's a casting
tool: give your French countess Siwis's Parisian lilt, your Spanish innkeeper
Alex's Madrid warmth, your wise elder Kumo's Japanese calm — all narrating
English text, all instantly understandable, all adding character color no
"neutral" voice could. (The roster's `LANG` column marks them all `en` for
exactly this reason.) The voice-id prefix tells you the accent (`af_`/`am_`
American, `bf_`/`bm_` British, `ef_`/`em_` Spanish, …). Meet the whole company:

#### 🇺🇸 American English — the headliners

| Voice | ID | Gender | Why you'll love it |
|-------|----|--------|--------------------|
| Heart | `af_heart` | female | Kokoro's crown jewel — the warmest, most natural read in the lineup |
| Bella | `af_bella` | female | rich, rounded, effortlessly expressive; a go-to heroine |
| Nicole | `af_nicole` | female | the whisperer — intimate close-mic delivery no other voice can touch |
| Aoede | `af_aoede` | female | named for the muse of song, and it shows: melodic, lyrical phrasing |
| Kore | `af_kore` | female | cool, composed, quietly commanding — perfect for stoic leads |
| Jessica | `af_jessica` | female | bright girl-next-door energy with real emotional range |
| Nova | `af_nova` | female | crisp and contemporary — podcast-anchor polish |
| Sky | `af_sky` | female | the beloved classic: light, friendly, instantly likable dialogue |
| Alloy | `af_alloy` | female | sleek and modern; a clean professional read that never tires |
| River | `af_river` | female | easy-going and free-flowing, great for laid-back narration |
| Sarah | `af_sarah` | female | steady, sincere, dependable — the voice you trust |
| Michael | `am_michael` | male | **the default narrator** — clear, steady, hours-of-listening comfortable |
| Adam | `am_adam` | male | deep, dependable leading man; anchors any scene |
| Onyx | `am_onyx` | male | dark velvet bass — pure gravitas |
| Fenrir | `am_fenrir` | male | the wolf: growl and edge that make villains unforgettable |
| Puck | `am_puck` | male | Shakespeare's trickster — mischief and charm on demand |
| Echo | `am_echo` | male | resonant with a touch of mystery |
| Liam | `am_liam` | male | youthful charm; your protagonist's best friend |
| Eric | `am_eric` | male | the solid everyman — always believable |
| Santa | `am_santa` | male | jolly, booming warmth (yes, he does bedtime stories) |

#### 🇬🇧 British English — period drama ready

| Voice | ID | Gender | Why you'll love it |
|-------|----|--------|--------------------|
| Emma | `bf_emma` | female | warm classic English — Austen adaptations write themselves |
| Alice | `bf_alice` | female | storybook charm straight out of Wonderland |
| Isabella | `bf_isabella` | female | elegant and refined; instant aristocracy |
| Lily | `bf_lily` | female | light and delicate, lovely for gentle scenes |
| George | `bm_george` | male | distinguished and stately — the lord of the manor |
| Fable | `bm_fable` | male | the name says it: a born storyteller's cadence |
| Daniel | `bm_daniel` | male | BBC-crisp diction, documentary-grade authority |
| Lewis | `bm_lewis` | male | assured and professorial; exposition in safe hands |

#### 🇪🇸 Spanish · 🇵🇹 Portuguese accents — the romance wing

English narration with genuine Spanish/Portuguese color — and when a line
actually *is* Spanish, these are the voices that pronounce it natively:

| Voice | ID | Gender | Why you'll love it |
|-------|----|--------|--------------------|
| Dora | `ef_dora` | female | reads English with genuine Spanish warmth; pronounces real Spanish natively |
| Alex | `em_alex` | male | smooth Spanish-accented English — and star of the bilingual POC |
| Santa | `em_santa` | male | Papá Noel himself — festive warmth with Spanish flair |
| Dora | `pf_dora` | female | the same warmth, Portuguese edition |
| Alex | `pm_alex` | male | easy Brazilian-Portuguese smoothness in English |
| Santa | `pm_santa` | male | ho-ho-ho, com sotaque português |

#### 🌍 The international wing — accents as casting gold

Every voice here reads **English** — clearly, comfortably — with an authentic
accent that makes international characters sound like themselves instead of a
generic narrator doing an impression:

| Voice | ID | Gender | Accent | Why you'll love it |
|-------|----|--------|--------|--------------------|
| Siwis | `ff_siwis` | female | 🇫🇷 French | English with effortless Parisian polish |
| Sara | `if_sara` | female | 🇮🇹 Italian | a musical Italian lilt on English lines |
| Nicola | `im_nicola` | male | 🇮🇹 Italian | expressive, animated Italian-accented English |
| Alpha | `jf_alpha` | female | 🇯🇵 Japanese | clean, bright English with Japanese cadence |
| Gongitsune | `jf_gongitsune` | female | 🇯🇵 Japanese | named for the fox of the famous folk tale — storyteller charm |
| Nezumi | `jf_nezumi` | female | 🇯🇵 Japanese | quick, light, playful |
| Tebukuro | `jf_tebukuro` | female | 🇯🇵 Japanese | soft as the mitten fable it's named after |
| Kumo | `jm_kumo` | male | 🇯🇵 Japanese | calm depth, quietly atmospheric |
| Xiaoxiao | `zf_xiaoxiao` | female | 🇨🇳 Mandarin | polished, versatile — a lead voice with Mandarin color |
| Xiaobei | `zf_xiaobei` | female | 🇨🇳 Mandarin | northern brightness and bounce |
| Xiaoni | `zf_xiaoni` | female | 🇨🇳 Mandarin | gentle and lyrical |
| Xiaoyi | `zf_xiaoyi` | female | 🇨🇳 Mandarin | expressive with a dramatic streak |
| Alpha | `hf_alpha` | female | 🇮🇳 Hindi | clear, friendly English with Hindi warmth |
| Beta | `hf_beta` | female | 🇮🇳 Hindi | softer counterpart with an easy flow |
| Omega | `hm_omega` | male | 🇮🇳 Hindi | deep, assured narration with Hindi character |
| Psi | `hm_psi` | male | 🇮🇳 Hindi | lighter, conversational energy |

### Cool things the cast can do

- **Gender-matched auto-casting** — the pipeline reads each character's gender
  from the LLM roster and casts a matching voice, most-spoken characters first,
  so leads get unique voices before anyone doubles up.
- **The narrator's voice is sacred** — reserved exclusively, never handed to a
  character, so the storyteller always sounds like the storyteller.
- **Audition before you commit** — `voice_mapper` plays any voice on any line
  in your browser; recast a character and only their lines re-render (WAVs are
  content-addressed by voice+text).
- **Bilingual lines** (POC, `en_sp_tts_poc/`) — embedded Spanish words rendered
  with correct Spanish pronunciation, either by a Qwen voice switching language
  mid-line or by seamlessly splicing in a native Spanish voice.
- **One engine per line, mixed freely per book** — Kokoro and Qwen voices sit
  in the same `voices_list.txt` roster and the same story can cast from both.

The roster lives in `voices_list.txt` (`NAME, GENDER, PRIORITY, LANG, VOICE ID,
MODEL`); the `PRIORITY` column controls casting order (`1` first, then `2`, …;
`0` = reserved from auto-casting, still available manually in voice_mapper).

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
