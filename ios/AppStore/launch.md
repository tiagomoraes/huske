# Launching Huske for iPhone

How to get Huske for iPhone in front of the people who would use it. The
store page is part of it; most installs will come from elsewhere.

Store facts and copy live in [`listing.md`](listing.md). The art lives in
[`art/`](art/): `capture.sh` (phone screens), `render.sh` (everything else).

## The one idea

**Record on your iPhone. Your Mac writes it down.** No cloud, no account.

Every piece repeats it: the store page, the site, the posts, the Mac app.
Proof points, in this order:
1. The words come back to the phone.
2. It keeps recording with the screen locked, with no app to open.
3. Nothing goes through a server. It's open source.

Who it's for, most likely to install first:
1. **People who already run Huske on a Mac.** They have the other half, so
   for them the iPhone app is a one-tap win.
2. **Privacy-minded Mac users who record** meetings, interviews, walks or
   voice notes, and won't send audio to a cloud.
3. **Markdown and Obsidian note-takers, and developers.** Transcripts land as
   Markdown files and can sync to a private Git repository their AI tools
   read.

## The store page

| Piece | Where | Status |
|---|---|---|
| Name, subtitle, keywords, description, promotional text | `listing.md` | in App Store Connect |
| Universal creative asset: product page header and search results card (5244×2950) | `art/header.html` | rendered |
| Five screenshots, 6.9" and 6.3" | `art/panels.html` | 6.3" set uploaded |
| App Preview video | none yet | recommended next |
| Privacy label, age rating (4+), price (free), availability | App Store Connect | done |

### Next, in order of impact

1. **Search results asset.** When it's present, App Store search shows it
   instead of the screenshots. Upload `out/universal.jpg` as both header and
   search results asset. Use the Preview tool in App Store Connect to check
   the crops.
2. **App Preview video**, 15–30 s, recorded on a real iPhone:
   - the Action button starts a recording;
   - the Live Activity runs on the Lock Screen;
   - Stop;
   - the transcript arrives.

   It must work muted, and its poster frame should be the transcript
   arriving. It's also the backbone of the App Review video (`listing.md`).
3. **Ask for a rating at the right moment.** Use `RequestReviewAction` (or
   `SKStoreReviewController`) after the third transcript comes back to the
   phone, never after an error. Guideline 5.6.1 requires the system prompt.
4. **Featuring nomination.** In App Store Connect, open Featuring →
   Nominations and nominate the launch, ideally a few weeks ahead. Pitch the
   local-first angle and the quiet design. Apple's editors read these.
5. **Product page optimization.** Once there's traffic, A/B test the first
   screenshot: the spoken-line panel against the recorder panel.
6. **Custom product pages.** Make two:
   - one for Huske for Mac users, linked from the Mac app, about pairing;
   - one for privacy-minded visitors.

   Each gets its own URL to link from its channel.
7. **Portuguese (Brazil).** Localize the product page and the panels' copy
   (panels.html holds all the text) once the app's interface is localized.
   String Catalogs are already on. Until then, a Portuguese page would promise
   an app that isn't.

## Channels we own (cheapest, highest intent)

1. **Huske.app's iPhone pane.** Add "Get Huske for iPhone" with the App Store
   link and a QR code. Everyone who opens that pane is a likely installer, so
   this is the smallest change with the largest effect. Ship it in the first
   Mac release after approval.
2. **The website** (PR #146, merged after approval). It already carries the
   copy and the link. Add:
   - **Smart App Banner:** `<meta name="apple-itunes-app" content="app-id=6838172707">`
     in `website/index.html` and `website/docs/index.html`. Safari on iPhone
     then offers the install at the top of the page.
   - **The official "Download on the App Store" badge** in the iPhone section,
     unmodified, as Apple's marketing guidelines require.
3. **GitHub.** Add an App Store badge to the README, put "Huske for iPhone is
   on the App Store" in the release notes, and pin the announcement on the
   repository.

## Launch week (channels we earn)

Post with a campaign link per channel (see Measuring). Answer every comment
the first day. Lead with what's true and checkable: local, open source, no
account.

- **Show HN.** "Show HN: Huske – record on your iPhone, your own Mac
  transcribes it (no cloud)". Tuesday to Thursday, US morning. Link the
  repository and the App Store page. Be ready for "why not on-device
  transcription on the phone?": the Mac's GPU and the existing engine.
- **Reddit.** Follow each subreddit's self-promotion rules:
  - r/macapps;
  - r/ObsidianMD (Markdown transcripts);
  - r/selfhosted (local-first, Git sync);
  - r/iphone.
- **Product Hunt.** Reuse the universal asset and the panels. Its gallery
  wants 1270×760; `header.html` renders it at any size.
- **Social.** Mastodon, Bluesky, X and LinkedIn: one short video (the App
  Preview) plus the line. Add a Portuguese post for the author's network,
  and TabNews for Brazilian developers.
- **Newsletters and blogs** that cover indie Mac and iOS tools. Send a
  personal note with the video, not a press release.

## Measuring

- **App Store Connect → Analytics:** impressions, product page views,
  conversion and downloads by source (search, browse, web referrer, app
  referrer).
- **Campaign links:** `https://apps.apple.com/app/id6838172707?pt=<provider token>&ct=<campaign>`.
  The provider token is in App Store Connect. Use one `ct` per channel:
  `site`, `mac-app`, `hn`, `reddit`, `ph`, `social`. They show which channel
  converts. Nothing else is measured: the apps have no telemetry, by design.

## Sequence

1. **Before submission:**
   - ship #145 so `/privacy/` and `/support/` are live;
   - shoot the review video;
   - fill in the App Review contact details.
2. **Submit.** Release manually, so the launch day is chosen.
3. **While in review:**
   - upload the universal asset;
   - prepare the App Preview, the Show HN text and the posts;
   - nominate for featuring.
4. **Launch day:**
   - release in App Store Connect;
   - merge #146 (site copy, banner, badge);
   - publish the release notes and the README badge;
   - post Show HN and the rest.
5. **Next Mac release:** the "Get Huske for iPhone" link in the iPhone pane.
6. **After the first reviews:** the rating prompt, promotional text updates
   with each release, and product page optimization.
