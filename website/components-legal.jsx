// huske website — the privacy policy (/privacy/) and support (/support/)
// pages. The App Store links to both from the product page, and the iPhone
// app links to both from its Mac screen. Keep them true to what the apps do:
// a change in what leaves a device changes this page in the same pull request.

const POLICY_UPDATED = "November 22, 2026";

const DATA_FLOWS = [
  {
    what: "Recordings, titles and transcripts on your iPhone",
    stays: "In Huske on your iPhone, outside iCloud backup",
    leaves: "Only to the Mac you paired, directly, encrypted with a key only those two devices hold",
  },
  {
    what: "Audio and transcripts on your Mac",
    stays: "In folders on your Mac (~/huske by default)",
    leaves: "Only if you turn on Cloud sync or cleanup with a cloud provider (below)",
  },
  {
    what: "Diagnostics",
    stays: "A short sync log on each device: states, sizes and errors, never audio, words, titles or names",
    leaves: "Only when you copy it yourself, for example into a bug report",
  },
  {
    what: "Anything about you",
    stays: "Nothing is collected: no account, analytics, advertising or tracking",
    leaves: "Never",
  },
];

const LegalHero = ({ title, children }) => (
  <header className="docs-hero">
    <div className="page">
      <h1>{title}</h1>
      <p className="docs-hero-lede">{children}</p>
    </div>
  </header>
);

const PrivacyPolicy = () => (
  <React.Fragment>
    <LegalHero title="Privacy policy">
      Huske doesn’t collect anything about you. There is no Huske server or account. What you record
      stays on your own iPhone and Mac, and goes elsewhere only when you turn on a feature that sends
      it, to a place you choose.
    </LegalHero>
    <div className="page legal-shell">
      <article className="docs-body">
        <section className="docs-sec">
          <p className="docs-aside">Last updated {POLICY_UPDATED}. It covers Huske for iPhone, Huske.app for the Mac and the <code>huske</code> command-line engine.</p>
          <div className="docs-table-wrap">
            <table className="docs-table legal-table">
              <thead>
                <tr><th>What</th><th>Where it stays</th><th>When it leaves, and to where</th></tr>
              </thead>
              <tbody>
                {DATA_FLOWS.map((r) => (
                  <tr key={r.what}><td>{r.what}</td><td data-label="Stays">{r.stays}</td><td data-label="Leaves">{r.leaves}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
          <p>
            Huske is open source, so every statement here can be checked in{" "}
            <a href={GH} target="_blank" rel="noopener">its code</a>. “We” means its maintainer,
            Tiago Moraes.
          </p>
        </section>

        <section className="docs-sec" id="iphone">
          <h2>Huske for iPhone</h2>
          <ul className="docs-bullets">
            <li><strong>Microphone.</strong> Used only while you record. iOS shows its recording indicator, and a Live Activity shows the recording on the Lock Screen.</li>
            <li><strong>Your recordings</strong> are stored in the app and left out of iCloud backup. Deleting one on the phone doesn’t delete the Mac’s copy.</li>
            <li><strong>Sending to your Mac.</strong> Recordings go only to the Mac you paired, over your local network or directly between the two devices. The connection is encrypted with a key that only those two devices hold. Transcripts come back the same way.</li>
            <li><strong>Camera.</strong> Used only to scan the pairing code your Mac shows. Nothing is saved.</li>
            <li><strong>Local Network.</strong> Used only to find your paired Mac.</li>
            <li><strong>Siri and Shortcuts</strong> read and control recordings on the phone. Nothing is sent anywhere.</li>
          </ul>
        </section>

        <section className="docs-sec" id="mac">
          <h2>Huske for Mac</h2>
          <p>Huske.app and the <code>huske</code> engine record your microphone and the audio your Mac plays while a session runs, and transcribe it on your Mac. On their own, they connect to the internet for two things:</p>
          <ul className="docs-bullets">
            <li><strong>Update checks.</strong> Once a day they ask GitHub and PyPI for the latest version number, and send nothing else. You can turn this off in Settings, or with <code>HUSKE_NO_UPDATE_CHECK=1</code>.</li>
            <li><strong>Model downloads.</strong> A transcription or language model downloads from Hugging Face the first time you use it.</li>
          </ul>
          <p>These features send data to a third party, and are off until you turn them on:</p>
          <ul className="docs-bullets">
            <li><strong>Cloud sync</strong> publishes transcript Markdown, never audio, to a private GitHub repository you choose. Signing in with the Huske Sync GitHub App gives Huske access only to the contents of the repositories you share with it, and the token stays in your Mac’s Keychain.</li>
            <li><strong>Cleanup with a cloud provider</strong> (OpenAI, Anthropic, OpenRouter or a server you name) sends transcript text to that one host, only after you allow it. Your API key stays in your Keychain.</li>
          </ul>
          <p>The provider’s own privacy policy applies to what you send it. Apple Intelligence, the built-in model and local servers such as Ollama keep cleanup on your Mac.</p>
        </section>

        <section className="docs-sec" id="apple">
          <h2>Apple</h2>
          <p>
            Apple delivers the iPhone app through the App Store and TestFlight under{" "}
            <a href="https://www.apple.com/legal/privacy/" target="_blank" rel="noopener">its own privacy policy</a>.
            If you chose to share analytics with app developers in iOS Settings, Apple may pass us
            anonymous crash reports and usage statistics. We use them only to fix problems.
          </p>
        </section>

        <section className="docs-sec" id="others">
          <h2>The people you record</h2>
          <p>
            Recordings and transcripts hold other people’s words. Tell people when you record them,
            and follow the law where you are. Keep a synced repository private.
          </p>
        </section>

        <section className="docs-sec" id="choices">
          <h2>Your choices</h2>
          <p>
            We hold no data about you, so there is nothing to request, export or delete from us.
            Delete recordings in the apps, or remove the apps and the <code>~/huske</code> folder.
            Cloud sync, cleanup and update checks each turn off in settings. Huske isn’t directed
            at children.
          </p>
        </section>

        <section className="docs-sec" id="contact">
          <h2>Changes and contact</h2>
          <p>
            When this policy changes, this page and its date change with it, and the history is
            public in the <a href={`${GH}/commits/main/website/components-legal.jsx`} target="_blank" rel="noopener">repository</a>.
            Questions go to <a href={`${GH}/issues`} target="_blank" rel="noopener">GitHub Issues</a>;
            report a security or privacy vulnerability privately, as <a href={`${GH}/blob/main/SECURITY.md`} target="_blank" rel="noopener">SECURITY.md</a> explains.
          </p>
        </section>
      </article>
    </div>
  </React.Fragment>
);

const SupportPage = () => (
  <React.Fragment>
    <LegalHero title="Support">
      Huske is maintained in the open. Questions, problems and ideas go to GitHub Issues, where the
      answer stays for the next person who needs it.
    </LegalHero>
    <div className="page legal-shell">
      <article className="docs-body">
        <section className="docs-sec" id="ask">
          <h2>Ask a question or report a problem</h2>
          <p>
            <a href={`${GH}/issues/new/choose`} target="_blank" rel="noopener">Open an issue</a> on GitHub,
            or <a href={`${GH}/issues`} target="_blank" rel="noopener">search the existing ones</a> first.
            You need a free GitHub account. Support is best effort, from the maintainer.
          </p>
          <h3>What helps</h3>
          <ul className="docs-bullets">
            <li>What you did, what you expected, and what happened instead.</li>
            <li>The app version and your iOS or macOS version. On the Mac, <code>huske --version</code> prints the engine’s.</li>
            <li>For sync problems, <strong>Copy details</strong>: on the iPhone it’s on the Mac screen, on the Mac in the iPhone pane. It holds states, sizes and errors, never audio, words or titles.</li>
          </ul>
          <p className="docs-aside">
            Never attach audio, transcripts, or screenshots that show private content. Issues are public.
          </p>
        </section>

        <section className="docs-sec" id="fixes">
          <h2>Common fixes</h2>
          <ul className="docs-bullets">
            <li><strong>The iPhone doesn’t reach the Mac.</strong> Open Huske on the Mac and keep it running, and allow Local Network access for Huske on the iPhone. <a href="../docs/#iphone">When it isn’t syncing</a> goes through the rest.</li>
            <li><strong>Pairing fails.</strong> Make a new code on the Mac: each one works once and expires after ten minutes.</li>
            <li><strong>The Mac records silence.</strong> Check Microphone and Audio Capture in System Settings › Privacy &amp; Security, or run Doctor in Huske.app.</li>
            <li><strong>Transcripts in the wrong language.</strong> Pick the spoken language in Configuration, as <a href="../docs/#transcription">Transcription</a> explains.</li>
          </ul>
        </section>

        <section className="docs-sec" id="security">
          <h2>Security</h2>
          <p>
            Report vulnerabilities privately, not in a public issue. <a href={`${GH}/blob/main/SECURITY.md`} target="_blank" rel="noopener">SECURITY.md</a> says how.
            How Huske handles your data is in the <a href="../privacy/">privacy policy</a>.
          </p>
        </section>
      </article>
    </div>
  </React.Fragment>
);

Object.assign(window, { PrivacyPolicy, SupportPage });
