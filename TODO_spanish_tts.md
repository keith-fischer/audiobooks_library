# TODO: Spanish word detection + correct TTS pronunciation (pipeline integration)

**Status: not started — pending POC results (see `en_sp_tts_poc/`).**

English-narrated audiobooks mispronounce embedded Spanish words ("fajita", "señor").
Verified live against local Voicebox (v0.5.0): `POST /generate` accepts a per-request
`language` code — regex `^(zh|en|ja|ko|de|fr|ru|pt|es|it|he|ar|da|el|fi|hi|ms|nl|no|pl|sv|sw|tr)$`,
default `en`. The **same voice profile speaks Spanish** by passing `language:"es"` —
no duplicate voice roster needed. The client (`vb/vbpoc.py:377-382`) never sends
`language` today.

Decisions already made:
- **Word-run granularity**: split mixed lines into per-language runs; each Spanish
  run gets its own small WAV (same voice, `language:"es"`), concatenated into the
  existing per-line WAV so downstream stitching is untouched and lines sound fluid.
- **Detection**: offline heuristic per chapter (wordfreq es-vs-en + diacritics) →
  ONE LLM confirmation pass per chapter over the flagged list → persisted
  per-chapter word-language file.
- **Workflow**: fully automatic + optional per-story override file (force/forbid).
- Start with Spanish; keep language codes generic (any of the 23).

---

## Key design decision: language runs join the WAV content address

Per-line WAV name = sha1 over `voice\ntext` (`vb/play_story_wav_files.py:95`
`_wav_name`), with skip-if-exists (`vb/script_to_wav.py:139`) and orphan deletion
(`script_to_wav.py:69-77`). Extend the hash with the run breakdown **only when a
line has a non-`en` run**:
- Pure-English lines keep the legacy hash → existing rendered libraries stay cached,
  zero regeneration.
- A mapping/override change → new hash for that line only → regenerates; the old
  WAV is cleaned up as an orphan. No `--force` needed.

## File formats (tab-delimited, in `stories/<base>/`, character_mapping style: col0 empty)

**Per-chapter map** `<base>_<label>_word_language.txt` (auto-written, atomic;
`#`/blank lines ignored; an EMPTY file means "detection ran, all-English"):

```
# word	lang	count	source	context
	fajita	es	3	llm	He ordered another fajita from the roadside stand.
	señor	es	7	heuristic	“Buenos días, señor,” said the guide.
```

Columns: word (lowercase, diacritics kept), lang (never `en`), count,
source (`override|llm|heuristic`), first-occurrence context (~70 chars).

**Per-story override** `<base>_word_language_overrides.txt` (optional, hand-authored):
`\t<word>\t<lang>`; `en` = forbid, any other code = force. Precedence: override >
chapter map. Applied at detection time (forbidden words never reach the LLM; forced
words bypass it) AND at load time in the run-splitter — an override edit takes
effect on the next render with no LLM re-run.

## Implementation steps

### 1. New module `language_detect.py` (project root)
- `heuristic_candidates(script_text)`: tokenize `[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]+(?:'\w+)?`;
  skip len≤2, ambiguous en/es stoplist (`no, a, me, he, sea, la, solo, era, con,
  mesa, …`), and words capitalized in *every* occurrence without diacritics
  (proper-noun guard). Accept when: has Spanish diacritics (`ñáéíóúü¿¡`) and
  `zipf_frequency(w,"en") < 3.5`; OR `zipf(es) ≥ 3.0` and `zipf(en) ≤ 2.5` and
  margin ≥ 1.5. If `wordfreq` unimportable → diacritics-only + warning.
- `llm_confirm(chat, candidates, label)`: ONE LM Studio call (existing
  `llm_client.py`) per chapter with per-word context; expect JSON
  `[{"word","lang"}]`; parse with `StoryScripter._extract_json` (staticmethod).
  Any failure → keep heuristic rows, warn.
- `detect_story(target, model=None, force=False) -> int`: per
  `<base>_<label>_script.txt` (post-reflow text = what's actually spoken), skip
  when the chapter map is newer than both the script and the override file; write
  atomically even when empty; return count (re)written. Create LLMClient lazily
  only when a chapter has unresolved candidates — pure-English books cost ~0.

### 2. `vb/play_story_wav_files.py`
- Add `load_word_langs(story, chapter)` (chapter map + override overlay; missing →
  `{}`) and `split_language_runs(text, word_langs) -> [(run_text, lang)]`.
  Boundary rule: split at the last whitespace between differing-lang tokens —
  closing punctuation stays with the left run; opening punctuation (`“‘("¿¡`)
  joins the right run; joined runs must round-trip to the original text.
- `_wav_name(voice, text, runs=None)` (line 95): all-`en`/None → legacy hash;
  else sha1 of `voice\ntext\n` + serialized runs. (Other call sites at
  403/423/535/612 stay valid via the default.)
- `resolve_chapter_cues` (line 183) returns 4-tuples `(lineno, voice, text, runs)`;
  update `play_chapter` (~423) and `merge_chapter_to_mp3` (~611). TSV-story path
  untouched.

### 3. `vb/vbpoc.py`
`_generate_to_wav(..., language=None)` (line 351):
`if language and language != "en": body["language"] = language`.

### 4. `vb/script_to_wav.py`
- `_generate_with_retry(..., language=None)` pass-through (line 37).
- New `_render_line(voice, text, runs, target, ...)`: single-`en`-run → today's
  direct path; else render each run to `f"{target}.run{i}.part"` (any failure →
  delete temps, return rc; existing repair sweeps at lines 161-178 re-attempt the
  whole line), then `_concat_runs_to_wav`.
- New `_concat_runs_to_wav`: decode via `_load_wav_mono` (rates must match — same
  profile/engine; mismatch = per-line error); **trim edge silence at seams**
  (trailing of non-final / leading of non-first clips down to ≤60ms below ~2% full
  scale — this removes the audible gap; no crossfade in v1); `np.concatenate`;
  write mono 16-bit via stdlib `wave` atomically (`.part` → `os.replace`).
  Crash-safe: `_reconcile_dir` already deletes `*.part`.
- `render_chapter` (line 80): 4-tuple cues; `expected = {_wav_name(v,t,r) ...}`
  (line 108); both loops use `_render_line`.

### 5. `main.py`
- `render_and_stitch`: 4-tuple unpack (lines 187, 196); add chapter word-language
  file + override file to `inputs_mtime` (line 198) so override edits stale the MP3.
- `_present_chapter_labels` (~340): exclude `_word_language` suffix and
  `word_language_overrides` — REQUIRED, else misclassified as "unexpected chapter
  files" by the regex at line 333.
- `_validate_chapter` (~362): add word-lang presence; compute expected WAVs with
  runs via the new pl helpers (imported ~455). Missing file → non-fatal
  "word-language file missing (assumed all-English)" so finished English projects
  keep passing. `print_validation` gains per-chapter `lang ok/—` flag + summary count.
- `_run`: new step after `normalize_scripts` (lines 799-801, before
  `assign_voices_to_unmapped` — must see post-reflow text):
  `n_lang = language_detect.detect_story(target, model=args.model, force=args.force)`
  unless new `--no-lang-detect`; runs in all modes incl. `--audio-only`.
  Audio-skip gate (line 814) gains `and n_lang == 0`.

### 6. Dependency
`requirements.txt`: add `wordfreq>=3.0` (verified NOT currently in `.venv`).
Graceful diacritics-only fallback if unimportable.

## Verification
1. **No-server unit checks**: run-splitter round-trips original text incl.
   punctuation attachment; `_wav_name(v,t) == _wav_name(v,t,[(t,"en")])`
   (legacy-hash invariant); heuristics flag `señor/fajita`, do NOT flag `no/Marbella`.
2. **Tiny test story** `stories/Lang Test.txt` (2 chapters, seeded with `fajita,
   señor, vámonos, cotias, no, Marbella`): stage 1 (`--no-audio`) → inspect the
   chapter map; add override (force `cotias`, forbid `fajita`) → re-run, overlay
   honored; full run with Voicebox up → multi-run log lines, new hashes, no
   leftover `.run*.part`, **listen to seams**; immediate re-run → fully cached
   (`n_lang == 0`, all WAVs skipped).
3. **Regression** on an existing English-rendered story + Carmen (genuinely
   Spanish-heavy): legacy WAV names unchanged for pure-English lines; validation
   still passes pre-migration.
