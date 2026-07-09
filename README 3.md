# voice_mapper

A small **local web GUI** to assign Voicebox voices to a story's characters, with
on-demand audio audition. It sits between scripting and audio render in the
`story_scripter` pipeline.

## What it does

1. **Pick a story folder that has chapter scripts** (`stories/<base>/` with
   `<base>_<N>_script.txt`). Only such folders are selectable.
2. See every character that speaks in those scripts, with its current voice and an
   "unmapped" flag.
3. **Audition** any voice (audio plays in your browser) and assign one per
   character.
4. **Save** — writes `stories/<base>/<base>_character_mapping.txt` in place
   (format preserved, so the rest of the pipeline reads it unchanged).

A second panel reconciles `voices_list.txt` (the static reference) against the
**live Voicebox voice list** (`getprofiles()`):

- `matched` — in both, safe to use.
- `reference only` — in the file but not a current Voicebox profile (will silently
  skip at render).
- `voicebox only` — available in Voicebox but missing from the file.

You can edit the reference table and **Export voices_list.txt** — it downloads to
your browser's Downloads (tab-delimited, same header). Move it to the project root
to apply.

## Run

```bash
# one-time: install the (single) dep into the shared project venv
.venv/bin/pip install -r voice_mapper/requirements.txt

# start it (leave running); Voicebox should be running for audition/cross-check
.venv/bin/python voice_mapper/server/app.py
# open http://127.0.0.1:5005   (deep link: /?story=Dracula)
```

The browser never calls Voicebox directly (no CORS) — all Voicebox calls are
proxied through the existing `vb/` client.

## Typical workflow

```bash
python main.py "Dracula.txt" --no-audio     # build scripts + initial mapping
#   ... open voice_mapper, pick Dracula, audition + assign, Save ...
python main.py "Dracula.txt" --audio-only   # render audio with chosen voices
```

`python main.py "Dracula.txt" --map` does the `--no-audio` step and prints the
voice_mapper launch command + deep link.
