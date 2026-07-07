# ADR-001: TTS Backend Architecture — Independent Scripts over Plugin Registry

> **Status**: Accepted | **Date**: 2026-03-28 | **Deciders**: cameron

## Context

peon-ping is adding text-to-speech (TTS) as a new output modality alongside pre-recorded sound files (v2/m5, PRD-003). The hook pipeline currently plays audio through a single `play_sound()` function that uses a platform `case` switch — one monolithic function handling macOS (`afplay`), WSL2 (PowerShell `SoundPlayer`), Linux (six-backend priority chain), SSH/devcontainer (relay HTTP), and MSYS2 (player chain + PowerShell fallback). This pattern grew organically and works, but it concentrates all platform logic in ~110 lines of shell with no separation between "what to play" and "how to play it."

TTS introduces a second axis of variation. Sound playback varies by **platform** (macOS vs. Windows vs. Linux). TTS varies by both **platform** (native engines differ per OS) and **engine** (native, ElevenLabs API, Piper local neural, future others). The roadmap explicitly plans three backend categories shipping at different times:

- **Platform-native** (Phase 1): macOS `say`, Windows SAPI5, Linux `espeak-ng`/`piper`
- **ElevenLabs** (future): Cloud API with audio caching, API key management, cost controls
- **Piper** (future): Local neural TTS with model management, BYO binary

These backends have fundamentally different operational characteristics. Native backends are synchronous CLI commands that speak directly to the audio device. ElevenLabs is an HTTP API that returns audio files requiring caching and playback. Piper is a local binary that writes WAV to stdout or file. A single abstraction that handles all three elegantly would need to bridge direct-to-device speech, cached file playback, and piped audio — three different I/O models.

Meanwhile, the existing `win-play.ps1` establishes a precedent: platform-specific audio logic extracted into a standalone script, invoked via `Start-Process` as a fire-and-forget background process. The Windows adapter ecosystem (`.ps1` counterparts for every `.sh` adapter) shows the codebase already handles dual-platform scripts as a known pattern.

The forces in tension:

1. **Extensibility**: New TTS engines must be addable without modifying the core hook pipeline. The roadmap plans at least three backends, and community contributions could add more.
2. **Simplicity**: peon-ping is a shell script, not a framework. Each layer of abstraction adds cognitive overhead for contributors and debugging surface area for users.
3. **Operational diversity**: Backends differ in I/O model (direct speech vs. file output vs. HTTP), lifecycle (stateless vs. cached), and configuration (none vs. API keys vs. model paths).
4. **Platform parity**: Both `peon.sh` (Unix) and `peon.ps1` (Windows) must implement the same TTS behavior, doubling the surface area of any abstraction layer.

## Decision

We will implement TTS backends as **independent, self-contained scripts** — one per backend per platform — invoked by the hook pipeline through a minimal calling convention rather than a formal plugin interface.

Each backend is a script that accepts speech parameters as command-line arguments and handles its own audio output asynchronously. The hook pipeline's only responsibility is: resolve the speech text, select the backend based on config, and invoke the corresponding script as a background process. There is no backend registry, no discovery mechanism, no shared backend library, and no abstract interface definition.

**Calling convention** (the entire "contract"):

```
# Unix (bash scripts) — text on stdin, options as arguments
echo "<text>" | scripts/tts-native.sh  "<voice>" "<rate>" "<volume>"

# Windows (PowerShell scripts) — text on stdin, options as named params
"<text>" | scripts/tts-native.ps1 -voice "<voice>" -rate <rate> -vol <volume>
```

Speech text is passed on **stdin**, not as a CLI argument. Dynamic text from template interpolation (`{project}`, `{summary}`) can contain shell metacharacters, quotes, newlines, and other content that is unsafe to pass as positional arguments without careful escaping. Stdin avoids this class of problems entirely — the backend reads one line from stdin and speaks it, with no shell interpretation of the content.

Each script:
- Reads speech text from stdin (one line)
- Handles its own platform detection internally (for native: macOS `say` vs. Linux `espeak-ng`/`piper`)
- Manages its own dependencies (ElevenLabs: HTTP + caching; Piper: binary + model detection)
- Exits cleanly on failure (no error propagation to hook — TTS failure is never a hook failure)
- Runs as a background process via the same `nohup ... &` / `Start-Process -WindowStyle Hidden` pattern as `play_sound()`

**Speech text resolution** happens in the hook pipeline's Python block (Unix) / PowerShell block (Windows) — centralized, before any backend is invoked:

1. If the selected sound entry has `speech_text` and TTS is enabled → interpolate template variables
2. Else if a notification template exists for this category → use rendered template text
3. Else → use default template `"{project} — {status}"`
4. If resolved text is empty after interpolation → skip TTS entirely

**Pipeline integration** in `_run_sound_and_notify` (or equivalent):

```
# Pseudocode — actual implementation adapts to mode config
if mode == "sound-then-speak":
    play_sound(file, volume)        # existing, backgrounded
    speak(text, voice, rate, vol)   # new, backgrounded after sound
elif mode == "speak-only":
    speak(text, voice, rate, vol)   # replaces sound
elif mode == "speak-then-sound":
    speak(text, voice, rate, vol)   # new, backgrounded
    play_sound(file, volume)        # existing, after TTS
```

TTS gets its own PID tracking (`.tts.pid`) separate from `.sound.pid`, enabling independent kill-previous behavior and the sequencing modes.

**File organization:**

```
scripts/
  tts-native.sh       # macOS say / Linux espeak-ng|piper
  tts-native.ps1      # Windows SAPI5
  tts-elevenlabs.sh   # (future) ElevenLabs API
  tts-elevenlabs.ps1  # (future) ElevenLabs API
  tts-piper.sh        # (future) Piper standalone
  tts-piper.ps1       # (future) Piper standalone
  tts-pockettts.ps1   # (N6UDP fork) pocket-tts CLI + optional serve daemon
  pockettts-serve.ps1 # (N6UDP fork) multi-session-safe pocket-tts daemon manager
  win-play.ps1        # (existing) Windows audio playback
```

## Rationale

The current sound playback system is a cautionary example of what happens when platform variation accumulates in a single function. `play_sound()` started as a simple `afplay` call and grew to 110 lines spanning six platform paths with nested conditionals for relay modes, WSL format conversion, and player priority chains. It works, but it's the single hardest function to modify confidently — every platform path must be mentally held in context for any change.

TTS would compound this problem because it adds engine variation on top of platform variation. An inline approach would mean the hook script grows a second 100+ line function with `case` branches for `native × {mac, linux, wsl, windows}`, `elevenlabs × {all platforms}`, and `piper × {all platforms}`. Each new backend multiplies the branch count.

Independent scripts avoid this by giving each backend its own file with its own concerns. `tts-native.sh` can have a platform `case` for `say` vs. `espeak-ng` without carrying ElevenLabs caching logic. `tts-elevenlabs.sh` can manage its HTTP client and cache directory without knowing anything about SAPI5. The complexity of each backend is **contained** rather than **composed**.

### Key Factors

1. **Operational isolation prevents cascade failures.** A bug in ElevenLabs caching logic cannot affect native TTS. A SAPI5 PowerShell quirk cannot break `espeak-ng`. This matters in practice — peon-ping runs in hook context where any failure delays the user's IDE. Independent scripts fail independently, and the hook pipeline's error handling is trivially simple: if the background process exits non-zero, nothing happens (fire-and-forget).

2. **The calling convention is the contract, and it's deliberately minimal.** Four arguments in, audio out. No interface file, no type system, no registration. This is a shell tool — the filesystem *is* the registry (`scripts/tts-*.sh` is the set of backends). A contributor adding a new backend writes one script, adds one `case` branch in the backend selector, and they're done. The barrier to contribution is "can you write a shell script that speaks text?" — not "can you navigate a plugin framework?"

3. **Backend diversity is real and resists unification.** Native TTS speaks directly to the audio device (no file output). ElevenLabs returns MP3 bytes over HTTP that need caching and playback through the existing audio pipeline. Piper writes WAV to stdout. A unified interface that abstracts these I/O models would either be so generic it provides no value (just "make audio happen") or so specific it forces backends into unnatural patterns (e.g., requiring file output from `say`, which natively speaks to device). The independent script model lets each backend use its natural I/O pattern.

4. **`win-play.ps1` already proves the pattern.** Windows audio playback was extracted into a standalone script precisely because it needed platform-specific complexity (MediaPlayer WPF dispatcher pumping, CLI player priority chains) that didn't belong inline. It works well — invoked via `Start-Process`, fire-and-forget, self-contained. TTS backends follow the same proven model.

## Consequences

### Positive

- **Each backend is independently testable.** `tts-native.sh` can be tested by invoking it directly with known arguments — no hook pipeline setup required. BATS tests call the script, Pester tests call the `.ps1`. This matches the existing test pattern for `win-play.ps1`.

- **New backends don't touch existing code.** Adding ElevenLabs means creating `tts-elevenlabs.sh` and adding a `case` branch in the backend selector — two changes, both additive. Zero risk to native TTS behavior.

- **Debugging is straightforward.** `peon debug on` can log the exact command invoked (`[tts] backend=native cmd="scripts/tts-native.sh 'hello' 'Alex' '1.0' '0.5'" pid=48291`). Users can run the same command manually to reproduce issues. The `[tts]` log phase slots naturally into the existing structured logging format.

- **Contributors face a minimal learning curve.** "Write a script that takes text/voice/rate/volume and speaks" is a self-contained task. No framework concepts to learn, no interfaces to implement, no registration to configure.

### Negative

- **Duplicated platform detection across backends.** `tts-native.sh` and a hypothetical `tts-festival.sh` would both need to detect macOS vs. Linux. This is a small amount of duplication (a `uname` check) and acceptable — the alternative (a shared platform library) adds a dependency chain to every backend script, creating the coupling we're trying to avoid.

- **Each backend requires parallel bash and PowerShell implementations.** Three planned backends means six script files with mirrored logic. This is the same dual-platform cost every peon-ping feature pays (every `.sh` adapter has a `.ps1` counterpart), but it multiplies with the backend count. Acceptable because each script is self-contained and small (~50-100 lines), and the alternative — a unified cross-platform layer — would introduce a new dependency or abstraction that doesn't exist in the codebase today.

- **No compile-time contract enforcement.** If a backend script ignores the volume argument or takes arguments in the wrong order, the only feedback is wrong behavior at runtime. For a shell-based CLI tool with 3-5 backends, this is manageable — backends are tested individually, and the argument list is documented in the script headers. A formal interface would only help if we had dozens of backends.

- **Backend selection is a hardcoded switch, not dynamic discovery.** The hook pipeline has a `case` block mapping config values to script paths. Adding a backend requires editing this block. Automatic discovery (scanning `scripts/tts-*.sh`) would eliminate this, but introduces ordering ambiguity and makes the "which backend runs?" question harder to answer from reading the code. Explicit is better than implicit for a system with <10 backends.

### Neutral

- **Speech text resolution stays centralized in the hook pipeline.** The Python block (Unix) and PowerShell block (Windows) handle template interpolation, manifest `speech_text` lookup, and variable resolution. Backends receive already-resolved plain text. This means the resolution logic exists in two places (Python and PowerShell), but this is the same pattern as every other hook feature — the Windows port mirrors the Python logic.

- **TTS PID tracking (`.tts.pid`) is separate from sound PID (`.sound.pid`).** This enables the three modes (`sound-then-speak`, `speak-only`, `speak-then-sound`) but means two PID files to manage. The kill-previous logic needs to respect both PIDs and the active mode. This is a small complexity increase with clear benefits for sequencing control.

## Alternatives Considered

### Alternative 1: Inline Platform Branching (Extend play_sound Pattern)

**Description**: Add TTS as another `case` block in the main hook script, mirroring how `play_sound()` handles platform variation. A single `speak()` function contains all backend logic — native platform detection, ElevenLabs HTTP calls, Piper invocation — as branches in a nested `case` structure (outer: backend, inner: platform).

**Pros**:
- All TTS logic visible in one place — no script-hopping to understand the full flow
- No process overhead — avoids the ~200ms PowerShell startup cost of a separate `Start-Process` on Windows (though this cost is already budgeted for `win-play.ps1` and fires in background)
- Consistent with how `play_sound()` currently works — contributors familiar with the codebase already know the pattern

**Cons**:
- Compounds the monolith problem. `play_sound()` at 110 lines is already the hardest function to modify; adding a `speak()` of similar size with backend × platform branching doubles the cognitive load. Each new backend adds branches to both Unix and Windows code paths
- Cross-backend contamination risk. A change to ElevenLabs caching could introduce a bug in native TTS if they share control flow or variables — even with careful scoping, inline proximity encourages shared state
- Testing requires the full hook pipeline. You can't invoke "just the native backend" without setting up mock config, event JSON, and platform detection — all the surrounding context that the inline function depends on

**Why not chosen**: `play_sound()` demonstrates the long-term trajectory of this pattern — organic growth into a function that's correct but increasingly difficult to modify with confidence. TTS would follow the same path with the added dimension of backend variation. The operational diversity of backends (direct speech vs. HTTP + cache vs. local binary) makes inline branches increasingly awkward as each backend's unique concerns bleed into shared scope.

### Alternative 2: Plugin Registry with Auto-Discovery

**Description**: Create a formal backend plugin system. Backend scripts live in a `tts-backends/` directory and self-register by implementing a standard interface. The hook pipeline scans the directory, loads available backends, and dispatches to the selected one. Each backend exports metadata (name, platform support, capabilities) that the registry uses for `auto` resolution and the `peon tts voices` enumeration.

A backend script would follow a defined structure:

```bash
# tts-backends/native.sh
BACKEND_NAME="native"
BACKEND_PLATFORMS="mac linux wsl"

backend_available() { ... }  # returns 0 if this backend can run
backend_voices() { ... }     # lists available voices
backend_speak() { ... }      # speaks text with given parameters
```

**Pros**:
- Maximum extensibility — community backends drop into a directory and "just work" without any core code changes
- Formalized contract prevents argument-order mistakes and documents the expected interface
- Auto-discovery enables features like `peon tts backends` listing all available engines with their capabilities

**Cons**:
- Overengineered for the expected scale. The roadmap plans 3-4 backends (native, ElevenLabs, Piper, maybe OpenAI). A discovery framework serves a plugin ecosystem of dozens — we're building for 3
- Introduces framework concepts foreign to the codebase. peon-ping is a shell script that reads JSON and plays sounds. Plugin registries, self-registration, and capability metadata are patterns from application frameworks, not CLI tools. Contributors now need to understand the plugin model before adding a backend
- Discovery ordering creates implicit behavior. If multiple backends claim to support a platform, which wins? Priority ordering, explicit preference configuration, and conflict resolution add complexity that explicit backend selection avoids entirely
- Shell-based plugin systems are fragile. Sourcing arbitrary scripts (`source tts-backends/*.sh`) in the hook's execution context risks variable collisions, function name conflicts, and error propagation. Subprocess isolation (what the independent scripts approach uses naturally) must be explicitly engineered

**Why not chosen**: The plugin registry solves a problem we don't have — managing a large, open-ended set of backends contributed by a distributed community. With 3-4 planned backends, each shipping as a deliberate feature with its own roadmap entry, the editorial overhead of "add a case branch" is negligible. The registry's value proposition — "zero-touch extensibility" — comes at the cost of framework complexity that makes the first three backends harder to build, debug, and maintain. If peon-ping ever reaches 10+ TTS backends (unlikely given the TTS market), a registry can be introduced then with the independent scripts as migration targets.

### Alternative 3: Unified Audio Pipeline (TTS as a Sound Source)

**Description**: Instead of TTS being a separate pipeline, treat synthesized speech as another sound source feeding into the existing `play_sound()` function. TTS backends produce audio files (WAV/MP3) written to a temp directory, and `play_sound()` plays them like any pack sound. This unifies PID tracking, volume control, kill-previous behavior, and platform playback under a single code path.

**Pros**:
- Maximal code reuse — every platform's audio playback is already solved in `play_sound()`. TTS backends only need to produce files, not handle audio output
- Single PID tracking (`.sound.pid`) — no dual-PID complexity, modes reduce to "play this file, then play that file"
- ElevenLabs and Piper naturally produce files (MP3/WAV), so this model fits them natively

**Cons**:
- Forces native TTS through an unnatural path. macOS `say` and `espeak-ng` speak directly to the audio device — requiring them to write files first adds latency (synthesis + write + read + play vs. just synthesis + speak) and temp file management (creation, cleanup, disk usage). A 2-second phrase would need to fully synthesize before any audio plays, rather than streaming word-by-word as `say` does natively
- Eliminates streaming playback. `say` begins speaking immediately as it processes text; file-based playback requires full synthesis first. For longer phrases (trainer progress with multiple exercises), the difference is perceptible — 1-2 seconds of silence before speech begins
- Conflates two concerns in `play_sound()`. Sound files are static assets selected from a manifest. TTS output is dynamically generated text. Adding "is this a real file or a temp file that needs cleanup?" logic to `play_sound()` spreads TTS concerns into the sound pipeline
- The sequencing modes (`sound-then-speak`, `speak-then-sound`) become harder — they're now "play file A, then play file B" which requires chaining `play_sound()` calls with wait-for-completion logic, adding the same PID coordination complexity we were trying to avoid

**Why not chosen**: The appeal of this approach — reusing `play_sound()` — breaks down precisely for the most important backend (platform-native). Native TTS's strength is low-latency direct-to-device speech, and forcing it through file intermediation sacrifices that advantage. The approach optimizes for API backends (ElevenLabs, which naturally produces files) at the cost of the baseline experience. Since native TTS is the first and default backend — the one every user encounters — penalizing it to benefit future backends is the wrong tradeoff ordering. API backends that produce files can simply call `play_sound()` internally if they want to reuse it, without forcing native backends into the same path.

### Alternative 4: Python Cross-Platform TTS (Single Script per Backend)

**Description**: Leverage the Python runtime already present in the hook pipeline (`peon.sh` embeds a Python block for config loading, event parsing, and sound selection). Each TTS backend becomes a single `.py` script that handles all platforms internally — `tts-native.py` would call `say` via subprocess on macOS, `espeak-ng` on Linux, and either `pyttsx3` or `win32com.client` for SAPI5 on Windows. This halves the file count by eliminating the `.sh` / `.ps1` duplication.

**Pros**:
- One script per backend instead of two — three backends means three files, not six
- Eliminates the "duplicated platform detection across backends" negative consequence entirely
- Python's `subprocess` module provides consistent cross-platform process invocation
- The hook pipeline already depends on Python (Unix side), so no new runtime dependency there

**Cons**:
- `peon.ps1` (native Windows) deliberately avoids Python — it's a pure PowerShell implementation with no Python dependency. Introducing Python TTS scripts would break this architectural boundary, requiring Python on Windows or maintaining a PowerShell fallback path anyway
- `pyttsx3` (the main cross-platform TTS library) is a pip dependency peon-ping has never required. The existing Python usage is stdlib-only. Adding pip dependencies changes the install story and creates a new failure mode
- Without `pyttsx3`, the Python scripts would just be subprocess wrappers around `say`/`espeak-ng`/SAPI5 — the same platform branching as shell scripts but in a different language, adding Python startup overhead (~100ms) without reducing complexity
- Python is not available in all environments where peon-ping runs (minimal containers, some CI images, MSYS2 without Python installed)

**Why not chosen**: The value proposition — halving file count — only materializes if a cross-platform Python TTS library is used, which introduces peon-ping's first pip dependency. Without it, Python scripts are just shell scripts in a different language with worse startup performance. More fundamentally, `peon.ps1` exists specifically to avoid a Python dependency on Windows, and that boundary is load-bearing — Windows users install peon-ping via `install.ps1` with no Python requirement. Forcing Python into the Windows path to reduce file count trades a real user-facing simplicity (no Python needed) for a developer-facing convenience (fewer files).

## Implementation Notes

**Phase 1 ships one backend script (native) with the integration layer:**

1. Add `tts` section to `config.json` defaults — `enabled: false`, `backend: "auto"`, `voice: "default"`, `rate: 1.0`, `volume: 0.5`, `mode: "sound-then-speak"`
2. Create `scripts/tts-native.sh` — platform detection (`uname`), macOS `say`, Linux `espeak-ng`/`piper` priority chain, async via `nohup ... &`
3. Create `scripts/tts-native.ps1` — Windows TTS via `System.Speech.Synthesis.SpeechSynthesizer` (SAPI5), async via the script being invoked through `Start-Process -WindowStyle Hidden` (same pattern as `win-play.ps1`). Note: Microsoft is steering toward `Windows.Media.SpeechSynthesis` (WinRT), which offers neural voices on Windows 11 with notably higher quality. Phase 1 uses SAPI5 for broader compatibility (Windows 10 support, simpler PowerShell integration), but the independent script architecture means `tts-native.ps1` can adopt WinRT internally without affecting any other backend or the hook pipeline
4. Add speech text resolution to the Python block in `peon.sh` — template interpolation using existing `_tpl_vars` machinery, outputting `TTS_TEXT` variable
5. Add TTS invocation to `_run_sound_and_notify` — mode-aware sequencing, `.tts.pid` tracking, safety timeout
6. Add `peon tts` CLI subcommands — `on`/`off`/`status`/`test`/`voices`/`voice`/`backend`
7. Port all of the above to `peon.ps1` (PowerShell)
8. `peon update` backfills `tts` config section for existing installs

**Future backends add files, not framework:**

- `scripts/tts-elevenlabs.sh`: HTTP client (`curl`), text-hash caching to `$PEON_DIR/cache/tts/`, plays cached MP3 via `play_sound()` internally
- `scripts/tts-piper.sh`: Detects `piper` binary and model, pipes text to `piper --output-raw | aplay` (or writes WAV + `play_sound()`)
- Each backend adds one `case` branch to the backend selector in `peon.sh` and `peon.ps1`

**The `auto` backend resolution** for Phase 1 is trivially `native` — it's the only backend. When ElevenLabs ships, `auto` can prefer it when an API key is configured, falling back to native. This logic lives in the hook pipeline's backend selector, not in any backend script.

## Validation

- **Backend isolation holds**: Each backend can be invoked directly from the command line (`echo "test" | bash scripts/tts-native.sh "Alex" "1.0" "0.5"`) and produces speech without any hook pipeline context. BATS/Pester tests validate this independently.
- **Hook latency unchanged**: Before/after timing of hook return shows no measurable increase. The structured logging `[exit] duration_ms=N` metric (from v2/m4) provides automated measurement. Target: <50ms delta.
- **Adding ElevenLabs backend requires no changes to tts-native scripts**: When `tts-elevenlabs.sh` ships, the diff touches zero lines in `tts-native.sh` or `tts-native.ps1`. Only the backend selector in `peon.sh`/`peon.ps1` and config schema gain additions.
- **Failure isolation**: Kill `espeak-ng` mid-utterance, corrupt the ElevenLabs cache, remove Piper's model file — each failure is contained to its backend with no impact on sound playback or other backends. The hook exits 0 regardless.
- **Contributor test**: The calling convention and one example script (`tts-native.sh`) are sufficient documentation for a new backend — implementing a backend requires no reading of `peon.sh` internals. If a contributor must understand the hook pipeline to write a backend, the contract has grown too complex.

## Related Decisions

- **Async Audio and Safe State on Windows**: The `Start-Process -WindowStyle Hidden` pattern, atomic state writes, and 8-second safety timeout established during the Windows native port. TTS backends inherit this pattern. (Implementation reference: `scripts/win-play.ps1` and `peon.ps1` async invocation.)
- **Structured Hook Logging** (v2/m4): The `[phase] key=value` log format defined for hook observability. TTS adds a `[tts]` phase following this convention.

## References

- [PRD-003: TTS Spoken Feedback](../prds/PRD-003-tts-spoken-feedback.md) — product requirements driving this decision
- v2/m5 "The peon speaks to you" — parent roadmap milestone defining feature sequencing and success criteria
- [macOS `say` man page](x-man-page://say) — native macOS TTS capabilities
- [System.Speech.Synthesis (SAPI5)](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis) — Windows native TTS API
- [espeak-ng](https://github.com/espeak-ng/espeak-ng) — open-source speech synthesizer for Linux
- [Piper](https://github.com/rhasspy/piper) — fast local neural TTS for Linux

---

## Revision History

| Date | Status | Notes |
|------|--------|-------|
| 2026-03-28 | Proposed | Initial proposal |
| 2026-03-28 | Accepted | Adversarial review: switched calling convention from CLI args to stdin for safe text transport; added platform parity cost as negative consequence; added Python cross-platform alternative (Alt 4); noted WinRT as SAPI5 successor; fixed dead design doc references |
