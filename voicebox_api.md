# Voicebox Local REST API — Developer Guide

A practical, grouped reference for the **Voicebox** desktop app's local HTTP API.
It explains what the API can and can't do, organized by feature rather than by the
flat alphabetical list the server ships.

- **Base URL:** `http://127.0.0.1:17493`
- **Spec version:** `voicebox API` v0.5.0 (OpenAPI 3.1) — **114 endpoints**
- **Interactive docs:** `http://127.0.0.1:17493/docs` (Swagger UI) ·
  full machine spec at `http://127.0.0.1:17493/openapi.json`
- **No auth.** It's a localhost-only service. The one meaningful header is
  `X-Voicebox-Client-Id` (see [Conventions](#2-conventions)).

> Sources: the live `/openapi.json` (authoritative for endpoints/fields) plus the
> public docs — [Architecture](https://docs.voicebox.sh/developer/architecture),
> [TTS Engines](https://docs.voicebox.sh/developer/tts-engines),
> [API Reference](https://docs.voicebox.sh/api-reference).

---

## Table of contents

1. [Overview](#1-overview)
2. [Conventions](#2-conventions)
3. [Architecture in brief](#3-architecture-in-brief)
4. [TTS engines](#4-tts-engines)
5. [Generate & Speak (the core)](#5-generate--speak-the-core)
6. [History](#6-history)
7. [Versions & effects](#7-versions--effects)
8. [Voice profiles (voices)](#8-voice-profiles-voices)
9. [Captures (dictation / clone source)](#9-captures-dictation--clone-source)
10. [Stories (multi-track timeline)](#10-stories-multi-track-timeline)
11. [Channels (output routing)](#11-channels-output-routing)
12. [Models & backend](#12-models--backend)
13. [Transcription (STT)](#13-transcription-stt)
14. [LLM helper](#14-llm-helper)
15. [MCP bindings](#15-mcp-bindings)
16. [Settings](#16-settings)
17. [System & lifecycle](#17-system--lifecycle)
18. [What you can / can't do](#18-what-you-can--cant-do)
19. [Cheat sheet (curl)](#19-cheat-sheet-curl)

---

## 1. Overview

Voicebox is a **local-first desktop app** (Tauri) that bundles a Python backend
exposing this REST API on `127.0.0.1:17493`. The API drives text-to-speech (7
engines), voice profiles & cloning, speech-to-text, a multi-track "stories"
editor, audio effects, and model management.

**Gotcha — "app open" ≠ "API up".** The GUI window can stay open while the Python
backend has crashed (e.g. a GPU error during a model download), leaving nothing
bound to the port. Always confirm before debugging a client:

```bash
curl -s http://127.0.0.1:17493/health   # JSON => up;  connection refused => restart the app
```

---

## 2. Conventions

| Topic | Detail |
|---|---|
| **Base URL** | `http://127.0.0.1:17493` |
| **Content type** | `application/json` for request bodies (file uploads use multipart) |
| **Client id header** | `X-Voicebox-Client-Id: <your-app-id>` — identifies your client for **per-client voice bindings** (see [MCP bindings](#15-mcp-bindings)). Optional but recommended. |
| **Errors** | FastAPI style: non-2xx returns `{"detail": "..."}` (string or validation array). 404 = unknown profile/id, 422 = bad body. |
| **Async generation** | TTS is **not** synchronous — you submit, then poll/stream a status, then download audio. See below. |
| **Serial GPU queue** | The backend runs **one generation at a time**. A stuck job head-of-line-blocks everything behind it; cancel it (`/generate/{id}/cancel`) or clear via `/history`/`/tasks`. |

**The async generation model (important):**

```
POST /generate ──► { id, status:"generating", duration:0 }   (returns instantly)
        │
        ▼
GET /generate/{id}/status   (Server-Sent Events: "data: {json}" frames,
        │                    ~1/s heartbeat, until status = completed | failed)
        ▼
GET /audio/{id} ──► WAV bytes
```

`POST /speak` is the same engine but **plays audio on the server host** and emits
events on `GET /events/speak`. Use `/generate` when *your* client should own
playback; use `/speak` for fire-and-forget "say this out loud here."

---

## 3. Architecture in brief

- **Desktop shell:** Tauri app = React/TypeScript UI + a **Python FastAPI** backend
  sidecar.
- **Backend:** hosts this REST API, a **pluggable TTSBackend engine registry**
  (all 7 engines behind one async interface), an STT engine, a **SQLite** store
  (profiles, history, stories, captures, channels), and audio processing.
- **Serial task queue:** GPU inference is serialized — generations run one at a
  time in submission order.

```
your client ──HTTP──► FastAPI ──► task queue ──► TTS engine (GPU) ──► WAV file + SQLite row
                          └────────► SSE status / events back to client
```

---

## 4. TTS engines

Pick an engine per generation (or let the profile's default decide). Only some
ship **preset voices**; the rest are **cloning** engines that need reference audio.

| Engine id | What it is | Preset voices? | Emotion via `instruct`? | Notes |
|---|---|---|---|---|
| `kokoro` | Fast, lightweight preset TTS | **Yes (50)** | ❌ ignored | Many en + multi-lang preset voices; no expressiveness control |
| `qwen` | Qwen3-TTS base | No (0) | ❌ dropped silently | General TTS; 0.6B / 1.7B model sizes |
| `qwen_custom_voice` | Qwen CustomVoice | **Yes (9)** | ✅ **honored** | **The only engine that respects `instruct`** (emotion/tone/pace) |
| `luxtts` | LuxTTS cloning | No | ❌ | Clone-from-sample |
| `chatterbox` | Chatterbox Multilingual | No | ❌ | Multilingual cloning |
| `chatterbox_turbo` | Chatterbox Turbo | No | ❌ | Faster Chatterbox |
| `tada` | TADA | No | ❌ | Cloning |

List the speakable presets for an engine:

```bash
curl -s http://127.0.0.1:17493/profiles/presets/kokoro            # 50 voices
curl -s http://127.0.0.1:17493/profiles/presets/qwen_custom_voice # 9 voices (instruct-capable)
```

> **Emotion summary:** delivery instructions like `"furious, shouting"` or
> `"whisper, intimate and close"` only change the audio on **`qwen_custom_voice`**.
> Every other engine ignores the `instruct` field.

---

## 5. Generate & Speak (the core)

| Method | Path | Purpose |
|---|---|---|
| POST | `/generate` | Render speech to a stored WAV (no server playback unless autoplay on) |
| POST | `/generate/stream` | Streaming generation |
| GET | `/generate/{id}/status` | **SSE** progress stream (→ completed/failed) |
| POST | `/generate/{id}/cancel` | Cancel an in-flight generation (unblock the queue) |
| POST | `/generate/{id}/retry` | Retry a failed generation |
| POST | `/generate/{id}/regenerate` | Re-run (e.g. new seed) |
| POST | `/generate/import` | Import external audio as a generation |
| GET | `/audio/{id}` | Download the rendered WAV |
| POST | `/speak` | Generate **and play on the server host** |
| GET | `/events/speak` | SSE stream of speak events |

### `POST /generate` — request body (`GenerationRequest`)

| Field | Type | Default | Meaning |
|---|---|---|---|
| `profile_id` | string | **required** | Saved profile id (from `/profiles`) |
| `text` | string | **required** | Text to speak |
| `language` | string | `"en"` | Language code |
| `engine` | string\|null | `"qwen"` | Override engine (else profile default) |
| `instruct` | string\|null (≤500) | — | **Delivery/emotion prompt** (qwen_custom_voice only) |
| `personality` | bool | `false` | If the profile has a personality prompt, rewrite text **in-character** via LLM before TTS |
| `seed` | int\|null | — | Reproducibility |
| `model_size` | string\|null | `"1.7B"` | e.g. `0.6B` / `1.7B` for Qwen |
| `max_chunk_chars` | int | `800` | Long-text chunk size |
| `crossfade_ms` | int | `50` | Crossfade between chunks (`0` = hard cut) |
| `normalize` | bool | `true` | Normalize output loudness |
| `effects_chain` | array\|null | — | Post-gen effects (overrides profile default) — see [Effects](#7-versions--effects) |

Response (`GenerationResponse`) includes `id`, `status`, `audio_path`,
`duration`, `instruct`, `engine`, `active_version_id`, `versions`.

### `POST /speak` — request body (`SpeakRequest`)

| Field | Type | Meaning |
|---|---|---|
| `text` | string (required) | Text to speak |
| `profile` | string\|null | Profile **name or id**; falls back to the client's MCP binding, then default |
| `engine` | string\|null | Engine override |
| `personality` | bool\|null | In-character rewrite (null = use the client binding's default) |
| `language` | string\|null | Language code |

> **Profiles only.** `profile`/`profile_id` resolve **saved profiles** (from
> `/profiles`). Passing a raw preset catalog name/`voice_id` returns 404 — see
> [Voice profiles](#8-voice-profiles-voices).

---

## 6. History

Every generation is recorded. Useful for finding stuck jobs, re-exporting, or
listing past audio.

| Method | Path | Purpose |
|---|---|---|
| GET | `/history` | List generations (`profile_id`, `search`, `limit`, `offset` query params) |
| GET | `/history/stats` | Aggregate stats |
| GET | `/history/{id}` | One generation |
| DELETE | `/history/{id}` | Delete a generation |
| GET | `/history/{id}/export` | Export metadata |
| GET | `/history/{id}/export-audio` | Export the audio |
| POST | `/history/{id}/favorite` | Toggle favorite |
| POST | `/history/import` | Import a generation record |
| DELETE | `/history/failed` | Clear all failed generations |

---

## 7. Versions & effects

A generation can have **multiple audio versions** — e.g. the clean original plus
effect-processed variants — with one marked default. Effects are a **chain** of
typed nodes applied as DSP.

**Available effect types:** `chorus`, `reverb`, `delay`, `compressor`, `gain`,
`highpass`, `lowpass`, `pitch_shift`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/effects/available` | List effect types you can chain |
| GET | `/effects/presets` · POST `/effects/presets` | List / create reusable effect presets |
| GET·PUT·DELETE | `/effects/presets/{preset_id}` | Manage one preset |
| POST | `/effects/preview/{generation_id}` | Preview an effects chain on a generation |
| GET | `/generations/{id}/versions` | List a generation's versions |
| POST | `/generations/{id}/versions/apply-effects` | Render a new version with an effects chain |
| PUT | `/generations/{id}/versions/{version_id}/set-default` | Choose the default version |
| DELETE | `/generations/{id}/versions/{version_id}` | Delete a version |
| GET | `/audio/version/{version_id}` | Download a specific version's audio |

`EffectConfig` = `{ type, enabled=true, params:{...} }`. `ApplyEffectsRequest` =
`{ effects_chain:[EffectConfig], source_version_id?, label?, set_as_default=true }`.

---

## 8. Voice profiles (voices)

A **profile** is a speakable voice. Two flavors:
- **Preset profile** — stores no audio, just a pointer to an engine voice id
  (e.g. Kokoro `am_adam`, Qwen CustomVoice `Ryan`).
- **Cloned profile** — stores one or more reference **samples**; the cloning
  engine builds a voice embedding at use time.

> **Profiles vs presets (key distinction):** `GET /profiles` returns the **saved
> profiles** whose names/ids `/speak` and `/generate` accept. `GET
> /profiles/presets/{engine}` returns the raw **preset catalog** — browse-only;
> those names are not directly speakable until saved as a profile.

| Method | Path | Purpose |
|---|---|---|
| GET | `/profiles` · POST `/profiles` | List / create profiles |
| GET·PUT·DELETE | `/profiles/{id}` | Get / update / delete a profile |
| GET | `/profiles/presets/{engine}` | Preset catalog for an engine |
| GET·POST | `/profiles/{id}/samples` | List / add reference samples (cloning) |
| PUT·DELETE | `/profiles/samples/{sample_id}` | Update / delete a sample |
| GET | `/samples/{sample_id}` | Download sample audio |
| GET·POST·DELETE | `/profiles/{id}/avatar` | Profile avatar image |
| POST | `/profiles/{id}/compose` | Generate **in-character text** for this profile (LLM) |
| PUT | `/profiles/{id}/effects` | Set the profile's default effects chain |
| GET·PUT | `/profiles/{id}/channels` | Get / set output channels for this profile |
| GET | `/profiles/{id}/export` · POST `/profiles/import` | Export / import a profile |

`VoiceProfileCreate` highlights: `name` (required), `language="en"`,
`voice_type="cloned"`, `preset_engine`, `preset_voice_id`, `default_engine`,
`design_prompt`, `personality` (the in-character rewrite prompt).

---

## 9. Captures (dictation / clone source)

A **capture** is a paired **audio + transcript** record (e.g. a dictation take or
a clip you want to clone from). You can re-transcribe, LLM-refine, or play it.

| Method | Path | Purpose |
|---|---|---|
| GET | `/capture/readiness` | Whether capture (mic/STT) is ready |
| GET·POST | `/captures` | List / create captures |
| GET·DELETE | `/captures/{id}` | Get / delete a capture |
| GET | `/captures/{id}/audio` | Capture audio |
| POST | `/captures/{id}/refine` | LLM-refine the transcript |
| POST | `/captures/{id}/retranscribe` | Re-run STT |
| GET·PUT | `/settings/captures` | Capture settings |

`CaptureCreateResponse` carries `transcript_raw`, `transcript_refined`,
`stt_model`, `llm_model`, `auto_refine`, `allow_auto_paste`, etc.

---

## 10. Stories (multi-track timeline)

The **stories** editor is a multi-track timeline for conversations, podcasts, and
narratives — each item references a generation placed on a track at a start time.
(Note: this repo's own story TSV/render pipeline is a *separate* client-side
concept; this is Voicebox's built-in editor.)

| Method | Path | Purpose |
|---|---|---|
| GET·POST | `/stories` | List / create stories |
| GET·PUT·DELETE | `/stories/{id}` | Get / update / delete a story |
| GET | `/stories/{id}/export-audio` | Render the whole timeline to audio |
| POST | `/stories/{id}/items` | Add an item (`generation_id`, `start_time_ms`, `track`) |
| PUT | `/stories/{id}/items/reorder` · `/items/times` | Reorder / retime items |
| PUT | `/stories/{id}/items/{item_id}/move` · `/trim` · `/volume` · `/version` | Edit one item |
| POST | `/stories/{id}/items/{item_id}/split` · `/duplicate` | Split / duplicate |
| DELETE | `/stories/{id}/items/{item_id}` | Remove an item |

---

## 11. Channels (output routing)

**Channels** map voices to audio output devices for multi-output setups (e.g.
route different characters to different speakers).

| Method | Path | Purpose |
|---|---|---|
| GET·POST | `/channels` | List / create channels |
| GET·PUT·DELETE | `/channels/{id}` | Manage a channel |
| GET·PUT | `/channels/{id}/voices` | Get / set the voices assigned to a channel |

---

## 12. Models & backend

Download, load/unload, and migrate the engine model weights. Models load lazily;
`loaded:false` with `downloaded:true` is normal until first use.

| Method | Path | Purpose |
|---|---|---|
| GET | `/models/status` | All models: downloaded/loaded/size |
| GET | `/models/progress/{model_name}` | Download progress for one |
| POST | `/models/download` · `/models/download/cancel` | Start / cancel a download |
| POST | `/models/load` · `/models/unload` | Load / unload into VRAM |
| POST | `/models/{model_name}/unload` · DELETE `/models/{model_name}` | Unload / delete one |
| POST | `/models/migrate` · GET `/models/migrate/progress` | Migrate model storage |
| GET | `/models/cache-dir` | Where weights live |
| GET·POST·DELETE | `/backend/cuda*` | CUDA backend status / download / remove (NVIDIA) |

Example models seen: `qwen-tts-1.7B`, `qwen-tts-0.6B`, `qwen-custom-voice-1.7B`
(HF repos under `mlx-community/Qwen3-TTS-*`).

---

## 13. Transcription (STT)

| Method | Path | Purpose |
|---|---|---|
| POST | `/transcribe` | Speech-to-text on an uploaded audio file (multipart) |

Returns `TranscriptionResponse` = `{ text, duration }`.

---

## 14. LLM helper

Voicebox bundles a small text LLM (used for personality rewrites, transcript
refinement, in-character compose). It's exposed directly:

| Method | Path | Purpose |
|---|---|---|
| POST | `/llm/generate` | Generate text |

`LLMGenerateRequest`: `prompt` (required), `system?`, `model_size="0.6B"`,
`max_tokens=512`, `temperature=0.7`, `examples?`. (Note: `temperature` is an
**LLM** control — there is no temperature knob for TTS.)

---

## 15. MCP bindings

Bind a **client id** (the `X-Voicebox-Client-Id` header) to a default voice/engine
so that client's `/speak` calls "just work" without specifying a profile.

| Method | Path | Purpose |
|---|---|---|
| GET | `/mcp/bindings` | List client bindings |
| PUT | `/mcp/bindings` | Create/update a binding |
| DELETE | `/mcp/bindings/{client_id}` | Remove a binding |

`MCPClientBindingUpsert`: `client_id` (required), `label?`, `profile_id?`,
`default_engine?`, `default_personality=false`.

---

## 16. Settings

| Method | Path | Purpose |
|---|---|---|
| GET·PUT | `/settings/generation` | Generation defaults |
| GET·PUT | `/settings/captures` | Capture defaults |

`GenerationSettingsUpdate` fields: `max_chunk_chars`, `crossfade_ms`,
`normalize_audio`, **`autoplay_on_generate`**. Live example:

```json
{"max_chunk_chars":800,"crossfade_ms":50,"normalize_audio":true,"autoplay_on_generate":false}
```

> **`autoplay_on_generate`** controls whether `/generate` *also* plays on the
> server. Disable it when your client owns playback (otherwise `/generate` speaks
> on the host on top of your local playback).

---

## 17. System & lifecycle

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Liveness + backend/GPU info (model_loaded, gpu_type, backend_type) |
| GET | `/health/filesystem` | Filesystem health |
| GET | `/` | Root |
| POST | `/shutdown` | Shut the backend down |
| POST | `/watchdog/disable` | Disable the watchdog |
| POST | `/cache/clear` | Clear caches |
| GET | `/tasks/active` | In-flight tasks (find stuck generations) |
| POST | `/tasks/clear` | Clear the task queue |

---

## 18. What you can / can't do

**You can:**
- Generate speech from text with 7 engines, 50+ Kokoro preset voices, and cloned
  voices from your own samples.
- Control **emotion/tone/pace** with `instruct` — **only on `qwen_custom_voice`**.
- Rewrite text **in-character** before TTS (`personality` + a profile personality).
- Apply a DSP **effects chain** (reverb, delay, compressor, eq, pitch, …) and keep
  multiple **versions** per generation.
- Clone voices from reference samples; dictate & transcribe (**STT**); refine
  transcripts with the built-in LLM.
- Build multi-track **stories** and route voices to **channels**.
- Manage model weights (download/load/unload/migrate).

**You can't (or watch out for):**
- **Emotion on kokoro / qwen-base / chatterbox / luxtts / tada** — `instruct` is
  silently ignored there.
- **Parallel TTS** — one serial GPU queue; a stuck job blocks the rest (cancel it).
- **Synchronous TTS** — `/generate` is submit-then-poll; build sync behavior client-side.
- **Speak a raw preset name** — only **saved profiles** are speakable.
- **No auth / remote use by design** — it's a localhost service.
- **No TTS temperature/seed-of-emotion** beyond `instruct`, `seed`, `model_size`.

---

## 19. Cheat sheet (curl)

```bash
BASE=http://127.0.0.1:17493
CID="-H X-Voicebox-Client-Id: my-script"

# Is it up?
curl -s $BASE/health

# List speakable profiles (names you can pass to /speak or /generate)
curl -s $BASE/profiles | python3 -c 'import sys,json;[print(p["name"]) for p in json.load(sys.stdin)]'

# Browse an engine's preset catalog
curl -s $BASE/profiles/presets/qwen_custom_voice

# Generate -> poll -> download WAV
ID=$(curl -s -X POST $BASE/generate -H 'Content-Type: application/json' \
      -d '{"profile_id":"<PROFILE_ID>","text":"Hello there."}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -sN $BASE/generate/$ID/status            # SSE: watch until "completed"
curl -s  $BASE/audio/$ID -o out.wav

# Emotional generation (qwen_custom_voice profile only)
curl -s -X POST $BASE/generate -H 'Content-Type: application/json' \
  -d '{"profile_id":"<QWEN_PROFILE_ID>","text":"You did this to me.","instruct":"furious, shouting"}'

# Speak out loud on the host
curl -s -X POST $BASE/speak -H 'Content-Type: application/json' \
  -d '{"text":"Deploy complete.","profile":"Nova"}'

# Transcribe an audio file
curl -s -X POST $BASE/transcribe -F 'file=@clip.wav'
```

---

### Sources
- Live spec: `http://127.0.0.1:17493/openapi.json` · Swagger UI: `/docs`
- [Voicebox Architecture](https://docs.voicebox.sh/developer/architecture)
- [Voicebox TTS Engines](https://docs.voicebox.sh/developer/tts-engines)
- [Voicebox API Reference](https://docs.voicebox.sh/api-reference)
