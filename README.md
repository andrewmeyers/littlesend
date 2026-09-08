# LittleSend

A macOS menubar app that takes an article URL, extracts the readable content
with the [Instaparser Article API](https://www.instaparser.com/docs/1/article_api),
builds an EPUB with a generated cover, and emails it to your Kindle.

## Setup

```bash
./Scripts/install.sh
```

That builds the app and installs it to `/Applications`. From then on it is a
normal Mac app — open it from Spotlight (⌘-Space, "LittleSend"), Launchpad, or
Finder; nothing in this repo needs to be running. To have it start
automatically, add it under System Settings → General → Login Items.

`./Scripts/build-app.sh` builds to `build/LittleSend.app` without installing,
and `./Scripts/install.sh ~/Applications` installs somewhere else.

The app lives in the menubar (no Dock icon). Open it and choose **Settings…**.

Everything is configurable; the fields are prefilled with sensible defaults:

| Setting | Default |
| --- | --- |
| Send to Kindle address | `andrew.meyers_sig@kindle.com` |
| From address | `andrew.meyers@gmail.com` |
| SMTP server / port | `smtp.gmail.com` / `465` |
| SMTP username | `andrew.meyers@gmail.com` |
| Email recipients | *(empty)* |

Settings edits a draft and commits it when you press **Save** (Revert discards).
Nothing is written until then, so a half-typed address never reaches the send
pipeline and the Keychain is touched once per save rather than once per
keystroke.

All settings, **including the Instaparser API key and the SMTP password**, are
stored in the app's UserDefaults plist in plain text. That file is readable by
any process running as you and is included in backups. Earlier versions used the
Keychain; anything still there is migrated across and cleared on first launch.

Gmail shows app passwords as four spaced groups (`abcd efgh ijkl mnop`) but the
credential itself has no spaces, so pasting it verbatim would fail to
authenticate. That exact shape is collapsed on save; any other password keeps
its spaces.

### Two things you have to do once, outside the app

1. **Create a Gmail app password.** Google rejects your normal account password
   over SMTP. With 2-Step Verification on, generate a 16-character app password
   at <https://myaccount.google.com/apppasswords> and paste it into Settings.
2. **Approve the sender with Amazon.** Add `andrew.meyers@gmail.com` to the
   Approved Personal Document E-mail List under *Manage Your Content and
   Devices → Preferences → Personal Document Settings*. Amazon silently drops
   mail from unapproved addresses — there is no bounce and no error.

## When the parser fails

Some sites refuse plain HTTP clients outright. `curl` of a gatesnotes.com
article returns **403** with no article markup at all, and Instaparser returns
**412 "could not extract"** for the same reason — its fetcher is refused too.
A real browser is served the page without complaint.

So a failed parse offers a **local reader**: the page is loaded in a hidden
`WKWebView` and Mozilla's Readability is run against the live DOM. Being an
actual browser is the whole trick; a side benefit is that client-rendered pages
have executed their JavaScript by the time the DOM is read.

It is **manual on purpose**. It is far slower than an API call and spins up a
web view, so it appears as a "Try" button after a failure rather than running
automatically. It is offered only when the hosted parser was what failed — a
delivery failure, or the local reader failing in turn, would not be helped by
it.

Readability is **vendored** at `Sources/LittleSendCore/Resources/Readability.js`
(Apache 2.0, © Arc90 Inc, pinned at 0.5.0) so the fallback needs no network of
its own and cannot drift. `Scripts/build-app.sh` copies it into
`Contents/Resources`, which is where `Bundle.main` looks — SwiftPM's own
`Bundle.module` accessor is unusable here, since it searches beside the bundle
root and otherwise a hardcoded `.build` path from the build machine, and calls
`fatalError` rather than returning nil.

## Destinations

Three destinations, independently switchable, all fed by the same parse:

- **Kindle** — the EPUB, mailed as an attachment to your Send to Kindle address.
- **Email** — the article as a formatted HTML message, to any number of
  addresses. Optionally attach the EPUB as well.
- **Desktop** — the EPUB written straight to `~/Desktop`. Needs nothing
  configured (no addresses, no SMTP), so it works on its own with just an
  Instaparser key. Sending the same article twice leaves both copies:
  the second becomes "Article 2.epub" rather than overwriting, the way a
  download would. Off by default — writing files to someone's Desktop
  uninvited should be asked for, not assumed.

**Settings never requires a destination.** It reports only what's genuinely
missing to send with — and nothing is mandatory on its own: configure a Kindle
address, email addresses, both, or neither if you only save to the Desktop.
SMTP credentials are only asked for once a mail destination actually exists.
Whether something is *selected* is a menu bar question, never a Settings one,
so Settings never nags about it.

**Settings only holds the address book — not what's active.** It stores the
Kindle address as a single field, and email addresses in a `Table` (an
actual macOS list with an Add field and a `–` button, not a comma-separated
text blob) that populates the picker. Adding an address there doesn't send
anything to it by itself. Whether Kindle or Email are on at all, and which of
the saved addresses actually receive a given send, is chosen entirely from the
menu bar popover — Settings deliberately has no "Send to Kindle" or "Send
email" toggle, so there's exactly one place selection happens.

Both destinations appear as controls in the popover, and both work the same
way: click the body to switch the destination on or off, click the chevron for
a dropdown of finer-grained choices. For Kindle that's just a plain toggle (no
dropdown needed); for Email, the dropdown lists every address from the
Settings table with its own checkbox, so a single on/off switch can still
target just one recipient or any subset. Turning email on or off is always a
deliberate top-level action — checking or unchecking one recipient in the
dropdown never does it as a side effect. Both chips fill solid when active,
using `bordered`/`borderedProminent` button styling — the same native pairing
macOS uses everywhere for "on" — and both are built from one shared
`DestinationButton` view (`Sources/LittleSend/DestinationButton.swift`), so a
destination added later gets identical styling for free rather than by copying
modifiers by hand. It's a plain `Button`, not SwiftUI's composite
`Menu(primaryAction:)`: that API did not reliably take the accent color when
filled — it rendered unaccented, then solid black, in testing — so a real
`Button` drives the on/off state and a small separate `Menu` (just the
chevron) opens the recipient list next to it. On/off state and which
recipients are checked are still persisted between launches — the change is
where you control them, not whether the app remembers your last choice.

They fail independently: if Kindle delivery fails, the email and the Desktop
copy still go out, and the popover reports which one broke. The EPUB is only built when something
actually needs it, so an email-only send skips cover rendering and image
downloads entirely.

Unlike the EPUB, the email keeps images as remote URLs — mail clients fetch them
on demand rather than carrying megabytes of base64 in every message.

The message is responsive and set in the system UI stack (`-apple-system`,
`Segoe UI`, Roboto, …). Because several mail clients drop `<style>` blocks
entirely, everything the layout depends on is applied **inline**: every image
gets `max-width:100%;height:auto`, tables and `<pre>` are constrained, and long
URLs are allowed to break. The stylesheet carries only enhancements — a
small-screen media query — so nothing essential is lost when it is stripped.
Verified at 375px: a 500px image scales to fit with its aspect ratio intact and
the document produces no horizontal scroll.

## Using it

Copy a link, click the menubar icon (the URL field prefills from the clipboard
when it holds a web address), press **Send**. The popover shows progress and
keeps a list of recent sends with per-item errors.

## How it works

```
URL → Instaparser → HTML→XHTML normalizer → image fetch → EPUB → MIME → SMTP → Kindle
```

`Sources/LittleSendCore` holds the whole pipeline and has no UI dependency, so
it is fully testable:

| File | Responsibility |
| --- | --- |
| `Instaparser.swift` | API client and error mapping |
| `ArticleTitle.swift` | Strips site branding from titles, using the `<h1>` |
| `ArticleEmailRenderer.swift` | Renders the article as an HTML email |
| `HTMLToXHTML.swift` | Tag-rewriting scanner producing well-formed XHTML |
| `ImageFetcher.swift` | Downloads article images, transcodes WebP/AVIF/HEIC to JPEG |
| `CoverGenerator.swift` | CoreText cover art in Possibility Bold |
| `EPUBBuilder.swift` | EPUB 3 package assembly and validation |
| `Zip.swift` | Dependency-free ZIP writer (stored entries) |
| `ImageResizer.swift` | Re-encodes oversized images to a byte ceiling |
| `SendArchive.swift` | Keeps the last five sends on disk, prunes the rest |
| `DesktopExporter.swift` | Writes the EPUB to the Desktop, stepping names aside |
| `MailMessage.swift` | RFC 5322 / MIME: multiple recipients, HTML, attachments |
| `SMTPClient.swift` | SMTP over Network.framework |
| `ArticleSender.swift` | Orchestration and configuration validation |

### Design notes

**The EPUB is always valid.** Article extractors emit loose HTML — unclosed
`<p>`, bare `&`, unquoted attributes, boolean attributes. `HTMLToXHTML` is a
scanner that guarantees well-formed output by construction: it normalizes and
quotes every attribute, self-closes void elements, drops unknown elements while
keeping their text, and uses an element stack to close anything left open. The
assembled body is then checked with `XMLParser`; if it somehow fails, the
builder falls back to a plain-text rendering rather than shipping a broken book.
Nesting is capped at 100 levels because libxml2 — and most EPUB readers —
refuse documents nested past ~256.

**No remote resources.** Images are downloaded and embedded. EPUB 3 only
guarantees JPEG/PNG/GIF/SVG, so anything else is transcoded to JPEG via ImageIO.
Images that fail to download have their `<img>` removed entirely, so a book
never references a URL the Kindle cannot reach.

**Image size.** Anything over the configured ceiling (600 KB by default) is
re-encoded to fit. Quality is given up before resolution — the first attempts
re-encode at full pixel size with falling JPEG quality, and only then does the
image start losing pixels, which keeps text in screenshots readable as long as
possible. Downsampling happens during decode, so the full-resolution bitmap is
never held in memory. If even the smallest attempt misses the target, the
smallest attempt is used rather than dropping the picture.

Because the embedded copy may be degraded, every image is wrapped in a link back
to its original URL — tap through for the full-resolution file. Images the
publisher already linked are left alone, since nested anchors are invalid.

Emails get the same treatment when "Embed images in the message" is on: the
shrunk copies travel in the message as `multipart/related` parts referenced by
`cid:`, so they always display with no "load remote images" prompt and no
network round-trip on the reader's side. Switch it off to link to the originals
instead and keep the message small. Images are downloaded once and shared
between both destinations.

**Recent sends.** Each send writes its EPUB, cover, email HTML and a short note
into a dated folder under `~/Library/Application Support/LittleSend/Recent
Sends`, and everything past the newest five is deleted. Files are written even
when delivery fails, so a rejected send still leaves an EPUB you can send by
hand. The popover's Recent list opens each folder in Finder.

**Titles.** Publishers put their own name in the `<title>`
("Kindle Direct Publishing - Wikipedia"), and Kindle shows that string in your
library. Trailing segments are dropped when they name the site — matched against
both the site name and the domain, so `theverge.com`, `The Verge` and `Verge`
all count. The article's own `<h1>` wins when it is a clear prefix of the title,
which catches publications whose branding is not guessable. Nothing is stripped
if it would leave less than three characters.

**Covers.** Rendered with CoreText at 1600×2560 in Possibility Bold. The
background tint is derived deterministically from the source domain, so
everything from one site looks related in the library grid. If the font is ever
missing, the app falls back to Georgia and tells you it did.

## Known limitation: SMTP requires implicit TLS

The connection is TLS from the first byte, which is what port 465 does.
Network.framework cannot upgrade a live connection, so **STARTTLS-only servers
are not supported** — notably Office 365, which offers only port 587. Gmail
supports 465, so this does not affect the default configuration. Supporting 587
would mean either raw sockets with the Security framework, or shelling out to
`curl`.

## Tests

```bash
swift test
```

249 offline tests cover the HTML normalizer's edge cases, ZIP and EPUB structure
(archives are read back and verified with `/usr/bin/unzip`), MIME encoding and
header-injection resistance, SMTP reply parsing and dot-stuffing, and cover
rendering.

There is also a live end-to-end check against the real API, skipped by default:

```bash
LITTLESEND_LIVE_KEY=… \
LITTLESEND_LIVE_URL=https://paulgraham.com/greatwork.html \
LITTLESEND_LIVE_OUTPUT=/tmp/littlesend \
swift test --filter LiveSmokeTests
```
