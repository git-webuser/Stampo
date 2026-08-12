# Security Policy

## Supported versions

Stampo is developed as a single line. Fixes go into the next release; there
are no maintained older branches. Always update to the [latest
release](https://github.com/git-webuser/Stampo/releases) before reporting an
issue.

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Anything older | ❌ |

## Reporting a vulnerability

Please report privately rather than in a public issue, so a fix can ship
before the details are public.

- **Preferred:** [open a private security advisory](https://github.com/git-webuser/Stampo/security/advisories/new).
- If that is unavailable to you, open a public issue that says only that you
  have a security report and how to reach you — no details.

What helps: the Stampo version (**Settings → About → Copy Diagnostics** gives
it along with the OS version), what you did, what happened, and what you
expected. A proof of concept is welcome but not required.

Expect an acknowledgement within a week. Stampo is a small project maintained
by one person, so please read that as a good-faith target rather than a
guarantee.

## What Stampo does with your data

The short version: it stays on your Mac. This is a design property worth
stating plainly, because a screenshot tool sees everything on your screen.

- **No uploads.** Screenshots, sampled colours and scanned text are never
  sent anywhere.
- **One optional network request:** once a day Stampo asks the GitHub API for
  the latest release version, to offer an update notification. It sends
  nothing beyond a standard HTTPS request, and it can be turned off in
  **Settings → General → Updates**. There are no other network requests.
- **Share** is the one way an image leaves the Mac, and only when you ask.
  Stampo writes the image to a temporary file and hands it to the macOS
  service you picked from the sheet; what that service does with it is
  between you and that app.
- **No analytics, no telemetry, no crash reporting.**
- **Diagnostic logs** contain no captured content, no file paths and no
  precise cursor positions.

## Scanned codes are inert

The scan feature reads QR codes and barcodes. Their payloads are treated
strictly as text: never opened, never linkified, never fetched. A malicious
QR code in a screenshot cannot make Stampo visit anything.

## Permissions and why they are needed

Stampo requires exactly one permission — **Screen Recording** — without which
it cannot take a screenshot or sample a colour. In particular it does **not**
require Input Monitoring, and it does not read your keystrokes:

- **Notch click** — a pair of standard AppKit mouse monitors that observe the
  location of a left mouse-down. They cannot modify or block events, and see
  nothing beyond whether the notch area was clicked.
- **Global hotkeys** — registered with Carbon's `RegisterEventHotKey`, so
  macOS only ever hands Stampo the exact combinations you assigned.
- **Esc to cancel** — a Carbon hotkey active only while a cancellable surface
  is on screen (the panel, the colour picker, a capture overlay, a hovered
  pin), removed as soon as that surface closes.

## Why the App Sandbox is disabled

Stampo runs with the App Sandbox disabled and the Hardened Runtime enabled.
This is an architectural requirement rather than an oversight: observing
mouse-down anywhere on screen, registering global hotkeys and invoking the
system `screencapture` tool are all impossible inside the sandbox.

Screenshots are taken with Apple's official APIs (ScreenCaptureKit and the
system `screencapture` tool), and saved files are reached through
security-scoped bookmarks.

## Distribution

Releases are signed with a Developer ID but are **not yet notarized**, which
is why macOS asks you to confirm the first launch. Install only from the
[Releases](https://github.com/git-webuser/Stampo/releases) page or the
project's Homebrew tap — a Stampo build from anywhere else is not one this
project produced.
