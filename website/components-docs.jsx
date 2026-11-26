// huske website — Docs page. Reuses the shared shell, Term, and InstallTabs.
//
// Version strings are intentionally absent: every version on the site comes
// from HUSKE_VERSION in version.js (the Nav carries it).

// ---- Small building blocks --------------------------------------------------

const DocsCode = ({ path, code }) => (
  <div className="docs-code">
    <div className="dc-head">
      <span>{path}</span>
      <CopyButton text={code}/>
    </div>
    <pre><code>{code}</code></pre>
  </div>
);

const DocsSection = ({ id, title, children }) => (
  <section id={id} className="docs-sec">
    <h2>{title}</h2>
    {children}
  </section>
);

const ConfigTable = ({ rows }) => (
  <div className="docs-table-wrap">
    <table className="docs-table">
      <thead>
        <tr><th>Key</th><th>Default</th><th>What it does</th><th>Flag</th></tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.key}>
            <td><code>{r.key}</code></td>
            <td className="dt-default">{r.def}</td>
            <td>{r.desc}</td>
            <td>{r.flag ? <code>{r.flag}</code> : <span className="dt-dash">–</span>}</td>
          </tr>
        ))}
      </tbody>
    </table>
  </div>
);

// ---- Scroll-spy for the sticky table of contents ----------------------------

function useScrollSpy(ids, offset = 96) {
  const [active, setActive] = React.useState(ids[0]);
  const key = ids.join(",");
  React.useEffect(() => {
    if (typeof window === "undefined" || !("IntersectionObserver" in window)) return undefined;
    const els = ids.map((id) => document.getElementById(id)).filter(Boolean);
    if (!els.length) return undefined;
    const obs = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((e) => e.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible[0]) setActive(visible[0].target.id);
      },
      { rootMargin: `-${offset}px 0px -64% 0px`, threshold: 0 }
    );
    els.forEach((el) => obs.observe(el));
    return () => obs.disconnect();
  }, [key, offset]);
  return active;
}

const DOCS_SECTIONS = [
  { id: "install", label: "Install" },
  { id: "first-run", label: "First run" },
  { id: "iphone", label: "iPhone" },
  { id: "transcription", label: "Transcription" },
  { id: "autostart", label: "Autostart on login" },
  { id: "config", label: "Configuration" },
  { id: "search", label: "Cloud sync" },
  { id: "connect", label: "VPS and MCP" },
];

const DocsToc = ({ active }) => (
  <aside className="docs-toc">
    <div className="docs-toc-inner">
      <p className="docs-toc-label">On this page</p>
      <nav aria-label="On this page">
        {DOCS_SECTIONS.map((s) => (
          <a key={s.id} href={`#${s.id}`} className={active === s.id ? "active" : ""}>{s.label}</a>
        ))}
      </nav>
      <div className="docs-toc-foot">
        <a href={GH} target="_blank" rel="noopener">Source</a>
        <a href={`${GH}/blob/main/examples/config.toml`} target="_blank" rel="noopener">Example config.toml</a>
        <a href={`${GH}/blob/main/docs/server.md`} target="_blank" rel="noopener">Server guide</a>
      </div>
    </div>
  </aside>
);

// ---- Hero -------------------------------------------------------------------

const DocsHero = () => (
  <section className="docs-hero">
    <div className="page">
      <h1>Set up huske</h1>
      <p className="docs-hero-lede">
        Install the Mac app, pair your iPhone, choose how transcripts are written, and, if you want,
        publish them to a private repository and an always-on agent service.
      </p>
    </div>
  </section>
);

// ---- Install ----------------------------------------------------------------

const InstallDoc = () => (
  <DocsSection id="install" title="Install">
    <p className="docs-lead">
      The fastest path is <strong>Huske.app</strong>: download it, open it, and one click installs
      the engine. The engine is also a single Python tool you can install on its own, for agents,
      SSH sessions and Macs without a screen.
    </p>
    <ul className="docs-facts">
      <li><span className="k">macOS</span><span>The app needs macOS 14 or later on Apple silicon. The engine runs on macOS 13 or later; 14.4 or later is recommended, because the Core Audio tap keeps working while you share your screen.</span></li>
      <li><span className="k">Python</span><span>{HUSKE_PYTHONS.slice(0, -1).join(", ")}, or {HUSKE_PYTHONS[HUSKE_PYTHONS.length - 1]}.</span></li>
      <li><span className="k">Disk</span><span>About 2.5 GB for the default Parakeet model, downloaded the first time you transcribe. Whisper large-v3 turbo in 4-bit is 0.5 GB.</span></li>
      <li><span className="k">Audio</span><span>No BlackHole and no Audio MIDI Setup: Huske uses Apple’s own capture.</span></li>
    </ul>

    <a className="btn btn-primary" href={APP_DOWNLOAD_URL}><DownloadGlyph/>Download Huske.app</a>
    <p className="docs-aside">
      Huske.app is signed with a Developer ID certificate and notarized by Apple, so it opens straight
      from the download: no right-click, no “Open Anyway”. macOS asks for Microphone and audio-capture
      permission the first time you record. If you’re upgrading from an older ad-hoc build, it asks
      once more, because the app’s identity changed; after that the permissions survive updates.
      A build you make yourself with <code>macos/scripts/build-app.sh</code> is signed ad hoc unless
      your keychain has a Developer ID.
    </p>

    <h3>The engine on its own</h3>
    <InstallTabs/>
    <p>
      The always-on MCP service is a separate Linux package, <code>huske-mcp</code>, under{" "}
      <code>services/huske_mcp</code>. See <a href="#connect">VPS and MCP</a>.
    </p>

    <h3>Prereleases and upgrades</h3>
    <p>Install an exact tag from the repository, or upgrade with the command for your install method:</p>
    <Term lines={[
      { cmd: 'uv tool install "git+https://github.com/tiagomoraes/huske.git@<tag>"', note: "a specific release tag" },
      { cmd: "uv tool upgrade huske" },
      { cmd: "pipx upgrade huske" },
      { cmd: "brew upgrade huske" },
    ]}/>
    <p className="docs-aside">
      Once a day the engine checks PyPI, and Huske.app asks GitHub, for the latest version number.
      <code> HUSKE_NO_UPDATE_CHECK=1</code> turns both checks off; the app also has a switch in
      Settings, and <strong>Huske → Check for Updates…</strong> checks on demand.
    </p>
  </DocsSection>
);

// ---- First run --------------------------------------------------------------

const FirstRunDoc = () => (
  <DocsSection id="first-run" title="First run">
    <p className="docs-lead">From a clean install to a transcript on disk.</p>
    <ol className="docs-steps">
      <li>
        <h4>Check your setup</h4>
        <Term lines={[{ cmd: "huske doctor" }]}/>
        <p>It checks Python, the model, your microphone, the system-audio backend, and that the output folders are writable. Huske.app’s Doctor pane shows the same checks with a fix for each. <code>huske doctor --json</code> prints them for scripts.</p>
      </li>
      <li>
        <h4>Grant the macOS permissions</h4>
        <p>Huske.app asks when you first record. When you run the engine from a terminal, allow these for your terminal app in <strong>System Settings → Privacy &amp; Security</strong>:</p>
        <ul className="docs-bullets">
          <li><strong>Microphone</strong>, for your voice.</li>
          <li><strong>Audio Capture</strong> (the Core Audio tap, macOS 14.4 and later) or <strong>Screen Recording</strong> (the ScreenCaptureKit fallback, and screenshots), for the audio your Mac plays.</li>
        </ul>
        <p className="docs-aside">A permission applies from the next launch: quit and start again after allowing it.</p>
      </li>
      <li>
        <h4>Record</h4>
        <p>In Huske.app, press <strong>Start Recording</strong> (<kbd>⌘</kbd><kbd>R</kbd>). The Record pane shows the levels, the current chunk and an activity feed; pause, screenshots, transcript cleanup and the microphone are one <kbd>⌘</kbd><kbd>K</kbd> away. From a terminal, the same engine runs headless:</p>
        <Term lines={[{ cmd: "huske run" }]}/>
        <p><kbd>Ctrl</kbd>+<kbd>C</kbd> finishes the current chunk, transcribes it and exits. A menu bar item has pause and stop.</p>
      </li>
      <li>
        <h4>Read the output</h4>
        <p>One Markdown file per stretch of conversation, with YAML frontmatter:</p>
        <DocsCode path="layout" code={"~/huske/transcripts/YYYY-MM-DD/HHMMSS_<session>_NNN.md"}/>
        <p>The <code>README.md</code> and <code>AGENTS.md</code> beside the day folders explain the format to any agent you point at it.</p>
      </li>
      <li>
        <h4>Recover after a crash</h4>
        <Term lines={[{ cmd: "huske recover" }]}/>
        <p>Audio is on disk as it’s captured. After a crash, <code>recover</code> (or the next session) transcribes what was left without recording it again. Audio that can’t be read moves to <code>~/huske/audio/incomplete/</code>.</p>
      </li>
    </ol>
  </DocsSection>
);

// ---- iPhone -----------------------------------------------------------------

const IPhoneDoc = () => (
  <DocsSection id="iphone" title="Huske for iPhone">
    <p className="docs-lead">
      A recorder that sends each recording to your Mac, where Huske transcribes it and sends the text
      back. It needs iOS 18 or later, and Huske.app running on the Mac.
    </p>

    <h3>Install it</h3>
    <p>
      <a href={IOS_APP_STORE_URL}>Huske for iPhone is free on the App Store.</a> On the phone it
      records, plays back and shares recordings by itself; transcripts come from the Mac you pair it with.
    </p>

    <h4>Or build it yourself</h4>
    <p>With Xcode 26 or later and XcodeGen:</p>
    <Term lines={[
      { cmd: "git clone https://github.com/tiagomoraes/huske.git" },
      { cmd: "brew install xcodegen" },
      { cmd: "cd huske/ios && ./scripts/generate.sh", note: "creates Huske.xcodeproj" },
      { cmd: "open Huske.xcodeproj" },
    ]}/>
    <p className="docs-aside">
      To run it on your phone, choose your team in Xcode’s Signing pane (or set{" "}
      <code>DEVELOPMENT_TEAM</code> in <code>ios/project.yml</code>). The <a href={`${GH}/blob/main/ios/README.md`} target="_blank" rel="noopener">iPhone README</a> has the details.
    </p>

    <h3>Pair it with your Mac</h3>
    <ol className="docs-steps">
      <li><p>In Huske.app, open <strong>iPhone</strong> and choose <strong>Pair iPhone</strong>.</p></li>
      <li><p>Point the iPhone’s camera at the code. The code works once and expires after ten minutes; right after pairing, the two apps swap it for a key that never leaves the two devices.</p></li>
      <li><p>Let Huske open at login when it offers to. The iPhone can only reach the Mac while Huske runs.</p></li>
    </ol>
    <p>
      Recordings travel over your Wi‑Fi, or directly between the devices (peer to peer) when the
      phone isn’t on a network. They enter the normal transcription queue on the Mac, and their
      transcripts are ordinary transcripts with <code>origin: phone</code>, <code>device</code> and{" "}
      <code>title</code> in the frontmatter.
    </p>

    <h3>Record without opening the app</h3>
    <ul className="docs-bullets">
      <li><strong>Action button:</strong> Settings › Action Button › Controls, then <strong>Huske Record</strong>. One press starts a recording; the next stops and saves it.</li>
      <li><strong>Control Center:</strong> add the same Huske Record control.</li>
      <li><strong>Siri and Shortcuts:</strong> “Start a Huske recording”, “Get my latest Huske transcript”, plus Stop, Pause or Resume, Get Transcript, Open Recording and Find Recordings.</li>
    </ul>
    <p className="docs-aside">Allow the microphone once from the app first: iOS only asks while the app is on screen.</p>

    <h3>When it isn’t syncing</h3>
    <p>
      The <strong>iPhone</strong> pane on the Mac says whether your iPhone can reach it right now and,
      when it can’t, why and what to do (for example, turn on Local Network access for Huske).{" "}
      <strong>Copy details</strong> copies that state with the recent sync log, which holds states,
      IDs, sizes and errors, never titles, audio or transcript text. A recording that couldn’t be
      transcribed has <strong>Try again</strong> on the Mac and <strong>Retry</strong> on the phone.
    </p>
  </DocsSection>
);

// ---- Transcription ----------------------------------------------------------

const TranscriptionDoc = () => (
  <DocsSection id="transcription" title="Transcription">
    <p className="docs-lead">
      Choose the model, say which language you speak, give Huske your words, and decide whether a
      second pass cleans the text up. Huske.app has all of this under Configuration.
    </p>

    <h3>The model</h3>
    <Term lines={[
      { cmd: "huske models", note: "the list: languages, size, speed, downloaded" },
      { cmd: "huske models try whisper-large-v3-turbo", note: "speed on this Mac, on a sample" },
      { cmd: "huske models use whisper-large-v3-turbo" },
      { cmd: "huske models convert <repo>", note: "a transformers Whisper fine-tune" },
    ]}/>
    <p>
      The choice is stored as <code>asr_model</code> and applies from the next recording. It also
      takes any compatible Hugging Face repo or a local folder. Parakeet, the default, works out the
      language from the audio (25 European languages); Whisper is locked to the language you choose.
      See <a href={`${GH}/blob/main/docs/transcription-models.md`} target="_blank" rel="noopener">transcription models</a> for
      measured speed and accuracy.
    </p>

    <h3>Language and dictionary</h3>
    <DocsCode path="~/.config/huske/config.toml" code={[
      'asr_model = "whisper-large-v3-turbo"',
      'language = "pt"',
      'vocabulary = ["Kubernetes", "OKR", "GitHub", "Marta"]',
      "",
      "[vocabulary_replacements]",
      '"cube ernetes" = "Kubernetes"',
      '"git hub" = "GitHub"',
    ].join("\n")}/>
    <p>
      <code>language</code> accepts <code>pt</code>, <code>pt-BR</code> or <code>Portuguese</code>;{" "}
      <code>huske languages</code> lists the codes and what each engine does with them. Whisper
      transcribes in that language only. Parakeet can’t be told a language, so Huske uses it to catch
      stretches that slip into English.
    </p>
    <p>
      Corrections in <code>vocabulary_replacements</code> apply to every transcript (whole words, any
      case), and casing like <code>OKR</code> is restored. Whisper also hears the vocabulary as its
      prompt. Set <code>parakeet_word_boost = true</code> to let Parakeet listen for the words too,
      at about 4–5 times the decoding time.
    </p>

    <h3>Transcript cleanup</h3>
    <p>
      Turn on <code>distill_enabled</code> and pick where it runs with <code>distill_backend</code>:{" "}
      <code>apple</code> (Apple Intelligence, on the Mac), <code>mlx</code> (the built-in model),{" "}
      <code>ollama</code>, <code>openai_compatible</code> (LM Studio, llama.cpp, vLLM),{" "}
      <code>openai</code>, <code>anthropic</code> or <code>openrouter</code>.
    </p>
    <Term lines={[
      { cmd: "huske llm status", note: "what’s missing, in plain words" },
      { cmd: "huske llm key set anthropic", note: "stored in the Keychain" },
      { cmd: "huske llm allow-cloud", note: "allow that one host" },
      { cmd: "huske llm test", note: "two made-up lines, nothing of yours" },
    ]}/>
    <p className="docs-aside">
      The raw transcript is written first and kept beside the cleaned one as{" "}
      <code>&lt;name&gt;.asr.txt</code>; the cleaned file records <code>postprocessed_by</code>. Any
      failure leaves the raw transcript in place. Nothing is sent off the Mac until you allow that
      exact host, and switching provider asks again.
    </p>

    <h3>Audio files you already have</h3>
    <Term lines={[
      { cmd: "huske import ~/Desktop/interview.m4a" },
      { cmd: "huske import --language pt reuniao.m4a" },
    ]}/>
    <p>
      m4a, caf, wav, flac, mp3 and more become ordinary transcripts, dated from the recording. A
      running <code>huske run</code> picks them up with its own model; otherwise a one-off pass
      transcribes them. They wait in <code>~/huske/inbox</code> (<code>huske inbox status</code>).
    </p>
  </DocsSection>
);

// ---- Autostart --------------------------------------------------------------

const AutostartDoc = () => (
  <DocsSection id="autostart" title="Autostart on login">
    <p className="docs-lead">
      In the app: <strong>Configuration → This app → Open Huske at login</strong> and{" "}
      <strong>Start recording when Huske opens</strong>. Prefer no app at all?{" "}
      <code>huske autostart install</code> registers a LaunchAgent that runs a headless{" "}
      <code>huske run</code> at every login.
    </p>
    <Term lines={[
      { cmd: "huske autostart install", note: "write the plist and load it" },
      { cmd: "huske autostart status", note: "installed, loaded, pid, last exit" },
      { cmd: "huske autostart start" },
      { cmd: "huske autostart stop", note: "graceful stop" },
      { cmd: "huske autostart uninstall" },
    ]}/>
    <p>
      Options: <code>--config &lt;path&gt;</code>, <code>--log-level</code>,{" "}
      <code>--keep-alive</code> / <code>--no-keep-alive</code> (restart on crash only, on by
      default), and <code>--force</code> to overwrite an existing plist. Logs go to{" "}
      <code>~/Library/Logs/huske/agent.out.log</code> and <code>agent.err.log</code>, and{" "}
      <code>huske doctor</code> reports the agent’s state.
    </p>
    <p className="docs-aside">
      If the permission prompts don’t appear after login, run <code>huske autostart start</code> once
      from a terminal, so they show while you’re there. Between chunks the transcription model is
      unloaded by default to keep idle memory low.
    </p>
  </DocsSection>
);

// ---- Configuration ----------------------------------------------------------

const COMMON_CONFIG = [
  { key: "asr_model", def: "unset", desc: "The transcription model: an id from huske models, a Hugging Face repo, or a local folder. Unset means Parakeet v3. Wins over the older asr_engine, parakeet_model and model keys.", flag: "--asr-model" },
  { key: "language", def: "unset", desc: "The spoken language, e.g. pt. Whisper transcribes in it only; Parakeet uses it to catch stretches that slip into English.", flag: "--language" },
  { key: "vocabulary", def: "[]", desc: "Names, products and jargon in your spelling, most important first.", flag: "" },
  { key: "vocabulary_replacements", def: "{}", desc: "What the engine wrote = what it should have written. Whole words, any case, every transcript.", flag: "" },
  { key: "parakeet_word_boost", def: "false", desc: "Let Parakeet listen for the vocabulary words (beam search, about 4–5× the decoding time).", flag: "" },
  { key: "distill_enabled", def: "false", desc: "Clean up each finished transcript with an LLM. The original is kept as <name>.asr.txt.", flag: "" },
  { key: "distill_backend", def: "mlx", desc: "Where cleanup runs: apple, mlx, ollama, openai_compatible, openai, anthropic or openrouter.", flag: "" },
  { key: "speech_gated", def: "true", desc: "Split files on real pauses in speech instead of a fixed clock. Silence isn’t recorded.", flag: "--speech-gated / --no-speech-gated" },
  { key: "silence_split_seconds", def: "60", desc: "Seconds of silence that close the current file (2–600).", flag: "--silence-split" },
  { key: "chunk_minutes", def: "15", desc: "Longest a file can be; files normally close on a pause.", flag: "--chunk-minutes" },
  { key: "echo_cancel", def: "true", desc: "Cancel the audio your speakers leak into the mic (WebRTC AEC3) before transcription. Does nothing with headphones.", flag: "--echo-cancel / --no-echo-cancel" },
  { key: "echo_canceller", def: "auto", desc: "auto (WebRTC AEC3, with the coherence suppressor as fallback), webrtc, or coherence (the older suppressor).", flag: "" },
  { key: "capture_sync", def: "true", desc: "Record mic and system audio from one Core Audio device, on one clock. Falls back to separate streams.", flag: "" },
  { key: "echo_dedup", def: "drop", desc: "Remove a leftover mic line that repeats a system line: drop, annotate, or off.", flag: "--echo-dedup" },
  { key: "system_audio_backend", def: "auto", desc: "System audio: auto, tap, sck, or off (microphone only).", flag: "--system-audio-backend" },
  { key: "input_device", def: "system default", desc: "Microphone name, matched by substring.", flag: "--input-device" },
  { key: "output_root", def: "~/huske/transcripts", desc: "Where Markdown transcripts are written.", flag: "--output-root" },
  { key: "audio_root", def: "~/huske/audio", desc: "Audio waiting to be transcribed (plus incomplete/).", flag: "--audio-root" },
  { key: "inbox_root", def: "~/huske/inbox", desc: "Recordings from the iPhone and from huske import wait here until transcribed.", flag: "" },
  { key: "keep_audio", def: "false", desc: "Keep audio after transcription, compressed (see keep_audio_format).", flag: "--keep-audio" },
  { key: "keep_audio_format", def: "opus", desc: "opus (smallest), flac (lossless) or wav.", flag: "--keep-audio-format" },
  { key: "screenshots_enabled", def: "false", desc: "Capture every display periodically. Loud: read Privacy first.", flag: "--screenshots" },
  { key: "screenshots_interval_seconds", def: "60", desc: "Seconds between screenshots (1–3600).", flag: "--screenshot-interval" },
];

const ADVANCED_CONFIG = [
  { key: "distill_model", def: "unset", desc: "The cleanup model; unset uses the backend’s default.", flag: "" },
  { key: "distill_endpoint", def: "unset", desc: "Base URL for ollama and openai_compatible servers. Never put credentials here.", flag: "" },
  { key: "distill_instructions", def: "\"\"", desc: "Extra instructions added to the cleanup rules, e.g. “Remove filler words.”", flag: "" },
  { key: "models_root", def: "~/huske/models", desc: "Where converted models are kept.", flag: "" },
  { key: "asr_engine", def: "parakeet", desc: "Older key: parakeet or whisper. Used when asr_model is unset.", flag: "--asr-engine" },
  { key: "parakeet_model", def: "parakeet-tdt-0.6b-v3", desc: "Older key: the Parakeet model when asr_model is unset.", flag: "--parakeet-model" },
  { key: "model", def: "base", desc: "Older key: the Whisper size when asr_engine is whisper and asr_model is unset.", flag: "--model" },
  { key: "whisper_idle_unload", def: "true", desc: "Drop the transcription model from memory between chunks; it reloads from the local cache.", flag: "--idle-unload" },
  { key: "whisper_idle_unload_seconds", def: "120", desc: "Idle seconds before the model is unloaded.", flag: "" },
  { key: "sample_rate", def: "48000", desc: "Capture sample rate (Hz).", flag: "" },
  { key: "logs_root", def: "~/huske/logs", desc: "Per-session log files.", flag: "" },
  { key: "menu_bar_enabled", def: "true", desc: "The menu bar item while recording.", flag: "--menu-bar" },
  { key: "screenshots_root", def: "~/huske/screenshots", desc: "Where screenshots go.", flag: "--screenshots-root" },
  { key: "screenshots_max_dimension", def: "1568", desc: "Downscale each screenshot’s long edge to this many pixels (0 disables).", flag: "--screenshot-max-dimension" },
  { key: "screenshots_jpeg_quality", def: "60", desc: "JPEG quality for screenshots, 1–100.", flag: "--screenshot-quality" },
  { key: "sync_enabled", def: "false", desc: "Publish each finished transcript.", flag: "" },
  { key: "sync_auth", def: "git", desc: "git uses this Mac’s own Git sign-in; github-app uses the Huske Sync app (Connect GitHub).", flag: "" },
  { key: "sync_remote", def: "unset", desc: "The private repository’s SSH or HTTPS remote.", flag: "" },
  { key: "sync_branch", def: "main", desc: "Branch for the transcript copy.", flag: "" },
  { key: "sync_root", def: "~/huske/sync", desc: "Huske’s own Git checkout; unpushed commits are the retry queue.", flag: "" },
  { key: "sync_push_timeout_seconds", def: "60", desc: "Time limit for each Git operation.", flag: "" },
];

const ConfigDoc = () => (
  <DocsSection id="config" title="Configuration">
    <p className="docs-lead">
      Everything lives in one optional TOML file. Precedence is{" "}
      <strong>defaults, then config.toml, then flags</strong>. Huske.app’s Configuration pane and{" "}
      <code>huske config set</code> edit it, and check every change with the engine, so a typo is
      an error, not a silent no-op.
    </p>
    <p>
      Several engines on one Mac (a uv tool, a Homebrew install) share the file and upgrade at
      different times, so a key an engine doesn’t know is ignored with a one-line warning instead
      of stopping it. Copy the commented{" "}
      <a href={`${GH}/blob/main/examples/config.toml`} target="_blank" rel="noopener">examples/config.toml</a>{" "}
      to see every key with its default.
    </p>
    <h3>Common keys</h3>
    <ConfigTable rows={COMMON_CONFIG}/>
    <details className="docs-details">
      <summary><Chev/>All other keys</summary>
      <ConfigTable rows={ADVANCED_CONFIG}/>
    </details>
  </DocsSection>
);

// ---- Cloud sync -------------------------------------------------------------

const SearchDoc = () => (
  <DocsSection id="search" title="Cloud sync">
    <p className="docs-lead">
      Huske.app can publish each finished transcript to a private GitHub repository. Connect GitHub
      signs in with the Huske Sync app: no SSH key, and access only to the contents of the
      repository you share with it.
    </p>
    <ol className="docs-steps">
      <li><p>Open <strong>Cloud sync</strong> in Huske.app and choose <strong>Connect GitHub</strong>. Enter the code on GitHub and approve Huske Sync.</p></li>
      <li><p>Create a <strong>private</strong> repository (Huske opens the form, filled in) and share only it with Huske Sync.</p></li>
      <li><p>Choose <strong>Publish here</strong>. Huske publishes what you have, then every new transcript.</p></li>
    </ol>
    <Term lines={[
      { cmd: "huske sync login", note: "enter the code on GitHub" },
      { cmd: "huske sync use you/huske-transcripts" },
      { cmd: "huske sync", note: "publish now" },
    ]}/>
    <p>
      Huske Sync can’t create, delete or reconfigure repositories. Its sign-in lasts eight hours,
      renews itself, and stays in your macOS Keychain. Prefer your own Git sign-in? Choose{" "}
      <em>Use an SSH key instead</em>, or set <code>sync_remote</code> to the repository’s SSH URL;
      Huske then stores no token at all.
    </p>
    <p>
      Only <code>transcripts/YYYY-MM-DD/*.md</code> enters the repository, plus a{" "}
      <code>README.md</code> and an <code>AGENTS.md</code> that explain it to agents (a file you wrote
      yourself is never overwritten). Audio, screenshots, the <code>.asr.txt</code> originals, logs,
      settings and credentials stay on the Mac. Huske pulls before each push, updates copies it
      published itself, never overwrites a transcript changed in the repository, and doesn’t
      re-add one you deleted there (<code>huske sync --republish &lt;path&gt;</code> does, on purpose).
    </p>
    <p>
      Claude, ChatGPT, Codex, Cursor and GitHub Copilot can read the repository through their own
      GitHub integration. Grant them only this repository, and turn off any setting that lets the
      vendor train on your content.
    </p>
    <p className="docs-aside">
      A sync error names its cause and the fix, and stays in the Cloud sync pane (and as a session
      warning) until a clean run clears it. Offline, sync keeps retrying for the whole session, and a
      new transcript syncs as soon as it can.
    </p>
  </DocsSection>
);

// ---- VPS and MCP ------------------------------------------------------------

const ConnectDoc = () => (
  <DocsSection id="connect" title="VPS and MCP">
    <p className="docs-lead">
      For indexed search that answers while the Mac sleeps, install the separate{" "}
      <code>huske-mcp</code> service on an always-on Linux host. It pulls the private repository,
      keeps its own index, and serves authenticated MCP.
    </p>
    <DocsCode
      path="/etc/huske-mcp/huske-mcp.env"
      code={"HUSKE_MCP_REPOSITORY=git@github.com:you/huske-transcripts.git\nHUSKE_MCP_BRANCH=main\nHUSKE_MCP_DATA_DIR=/var/lib/huske-mcp\nHUSKE_MCP_HOST=127.0.0.1\nHUSKE_MCP_PORT=7641\nHUSKE_MCP_POLL_SECONDS=60\nHUSKE_MCP_TOKEN_FILE=/etc/huske-mcp/token\nHUSKE_MCP_ALLOWED_HOSTS=huske.example.com"}
    />
    <Term lines={[
      { cmd: "huske-mcp doctor" },
      { cmd: "huske-mcp sync", note: "first pull and index" },
      { cmd: "huske-mcp serve" },
    ]}/>
    <p>
      Agents connect to <code>https://huske.example.com/mcp</code> with an{" "}
      <code>Authorization: Bearer &lt;token&gt;</code> header. The tools are <code>overview</code>,{" "}
      <code>recap</code>, <code>search</code>, <code>fetch</code> and <code>sync_status</code>.
    </p>

    <h3>Made for a small server</h3>
    <p>
      The default <code>tiny</code> profile is one process and one poll thread, with SQLite FTS5, an
      8 MB page cache and a 32 MB mmap ceiling. It loads no embedding model and is the supported
      profile for 1 vCPU and 512 MB. The optional <code>semantic</code> profile adds Model2Vec hybrid
      retrieval and needs more memory.
    </p>

    <h3>Polling, with a webhook to hurry it</h3>
    <p>
      Polling is what keeps the index correct, and it heals missed deliveries and restarts. An
      optional signed GitHub push webhook at <code>/webhooks/github</code> only wakes the poller
      early; the request itself never runs Git or indexing.
    </p>

    <h3>Security</h3>
    <ul className="docs-bullets">
      <li><strong>A bearer token is required,</strong> even on loopback, because a reverse proxy can publish a loopback listener.</li>
      <li><strong>Host validation stays on.</strong> List the proxy hostname in <code>HUSKE_MCP_ALLOWED_HOSTS</code>.</li>
      <li><strong>The deploy key is read-only.</strong> The service never pushes or changes its checkout.</li>
      <li><strong>The index is derived.</strong> SQLite lives outside Git and can be rebuilt from the Markdown.</li>
      <li><strong>The server holds plain text.</strong> Encrypt its disk, and expose it through TLS or a private network.</li>
    </ul>
    <p>
      systemd, Docker, deploy keys, reverse proxy, webhook and client setup are in the{" "}
      <a href={`${GH}/blob/main/docs/server.md`} target="_blank" rel="noopener">server guide</a>.
    </p>

    <h3>No MCP where you’re going?</h3>
    <p>
      <code>huske export</code> writes one Markdown digest per day for a Claude Project, NotebookLM,
      Obsidian or another document tool. It’s separate from the synced repository.
    </p>
  </DocsSection>
);

// ---- Page -------------------------------------------------------------------

const Docs = () => {
  const active = useScrollSpy(DOCS_SECTIONS.map((s) => s.id));
  return (
    <React.Fragment>
      <DocsHero/>
      <div className="page docs-shell">
        <DocsToc active={active}/>
        <article className="docs-body">
          <InstallDoc/>
          <FirstRunDoc/>
          <IPhoneDoc/>
          <TranscriptionDoc/>
          <AutostartDoc/>
          <ConfigDoc/>
          <SearchDoc/>
          <ConnectDoc/>
        </article>
      </div>
    </React.Fragment>
  );
};

Object.assign(window, { Docs });
