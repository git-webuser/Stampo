# Local Stampo E2E

XCTest target `StampoE2ETests`, shared scheme `StampoE2E`. The `Stampo` scheme
and CI remain unchanged. Run locally on an awake, unlocked Mac with ≥5 GB free.
Before the first UI run in a session, describe the scenario and duration, ask
the user to close Stampo and leave mouse/keyboard alone, and wait for “yes”.
Only the user grants permissions or enters a password in a system dialog.

```bash
bash Scripts/run-e2e.sh --build-only
bash Scripts/run-e2e.sh --only S0
bash Scripts/run-e2e.sh --only S0/testPanelLifecycle --iterations 5
bash Scripts/run-e2e.sh --no-build --only S0 --seed 12345
# Explicit authorization to close running copies gently and restore their paths:
bash Scripts/run-e2e.sh --take-over --only S0
```

`STAMPO_E2E_DEV_APP_PATH=/absolute/path/Stampo.app` overrides the dev copy whose
signature is checked. Otherwise the script resolves it from the primary
checkout's Xcode build settings. No dev build is built or signed by this script.
`--no-build` requires the source fingerprint of the verified build to match and
uses `test-without-building`. Normal runs use `xcodebuild test`. Iterations are
passed only for N > 1. Zero executed tests or skipped tests fail the run.
`STAMPO_E2E_SEED` or `--seed` sets the UInt64 seed; every scenario prints it.
Random scenarios must use this seed for every random choice.

The test app is `build/e2e/Stampo-E2E.app`, bundle id
`com.hex000.Stampo.e2e`, signed with Apple Development. Its launch arguments
set English, the per-scenario capture directory and completed onboarding.
`-StampoE2E` resets only that identity's preferences, uses default hotkeys,
keeps an empty archive in memory and suppresses automatic update checks.
`-StampoE2EFixture` creates a normal window with 300×200 content, red on the
left and blue on the right, centered on the primary display. U9 established
that Stampo can capture its own ordinary window. `-StampoE2EOpenEditor <PNG>`
opens a supplied PNG. All hooks and their call sites compile out of Release.
`AppDelegate.isRunningTests` is intentionally unchanged: startup is checked
without assuming XCTest environment variables are present in the app process.

## Permissions

Grant Accessibility to `build/e2e/DerivedData/Build/Products/Debug/StampoE2ETests-Runner.app`
(`com.hex000.StampoE2ETests.xctrunner`). The runner needs it for HID input and
AX responsiveness checks. The explicit runner entitlement disables App Sandbox;
the script inspects the signed runner before executing tests.

Captures require Screen Recording for **Stampo-E2E.app**, not the user's Stampo.
The system may show an additional capture authorization dialog even after
Screen Recording preflight succeeds. The user handles it. XCUIScreen supplies
step screenshots; CLI screencapture permission is separate. Developer automation
may ask for a system password while DevToolsSecurity is disabled. Do not enable
it or alter System Settings automatically. Stop on a prompt for the dev identity.

## Input and assertions

The primary path is CGEvent posted at the HID tap, including global
`input.press("⌃⌥⌘N")`. U5 also confirmed XCTest `typeKey`, explicit modifier
key-down/up events and fixture-window `typeKey`; those remain alternatives,
not automatic retries. Mouse clicks, drags and scrolls use CGEvent. Drags have
24 steps at 15 ms. Coordinate conversions come from
`Stampo/CaptureOverlayShared.swift`, commit `6919d04`; XCUI frames are already
in Quartz coordinates. Input starts by parking away from the notch.

One scenario is one method, ≤90 seconds. Wait for conditions with a deadline;
do not add sleeps to hide races. Fixed pauses >1 s need a reason. Assert that an
element exists before reading its value. Identify the panel via descendants:
its AX role is Dialog, and its mode/delay controls are MenuButtons.

Files go only in temporary directories or `build/e2e`. `Files.Bitmap` draws
the embedded-profile PNG into an explicit sRGB context before reading RGBA.
Compare known fixture/export/capture pixels, with ±2 where required. Do not
compare Stampo interface screenshots against golden images.

## Identifiers

Identifiers add no labels, values, controls or visual changes. Both editor
layout paths use the same ids, but only one is present at a time. AppKit popup
ids are set directly on their NSPopUpButton, because SwiftUI wrappers swallow
them. Settings toolbar items use their native itemIdentifier; sidebar rows use
SwiftUI identifiers. Editor/settings/archive ids are source mappings; S0 checks
only status/panel controls, not every editor and settings path at runtime.

| Brief item | Current control | Identifier |
|---|---|---|
| Status item (readiness) | NSStatusBarButton | `stampo.status.item` |
| Panel (Dialog) | NSPanel | `stampo.panel.window` |
| Close panel | close icon button | `stampo.panel.close` |
| Capture mode | AppKit popup | `stampo.panel.modeMenu` |
| Capture delay | AppKit popup | `stampo.panel.delayMenu` |
| Archive toggle | archive icon button | `stampo.panel.archiveToggle` |
| More menu | AppKit popup | `stampo.panel.moreMenu` |
| Settings / Quit | status menu items | `stampo.statusMenu.settings`, `stampo.statusMenu.quit` |
| Five settings tabs | toolbar item / sidebar row | `stampo.settings.tab.general`, `.capture`, `.archive`, `.hotkeys`, `.about` |
| Select / line / arrow / text / step | native toolbar toggles / legacy buttons | `stampo.editor.tool.select`, `.line`, `.arrow`, `.text`, `.step` |
| Rectangle / oval | Shapes popover cells | `stampo.editor.tool.rectangle`, `.oval` |
| Blur / loupe | Shapes popover cells | `stampo.editor.tool.blur`, `.loupe` |
| Drawing | Drawing family trigger | `stampo.editor.tool.drawing` |
| Eraser | Drawing popover cell | `stampo.editor.tool.eraser` |
| Scan / crop | native toggles / legacy buttons | `stampo.editor.tool.scan`, `.crop` |
| Canvas | EditorCanvasView | `stampo.editor.canvas` |
| “Украшение” / Decor | inspector toggle / legacy button | `stampo.editor.decor` |
| Archive header | existing header HStack | `stampo.archive.header` |
| Archive cell | current array position (zero-based) | `stampo.archive.cell.<index>` |

Additional current controls: `stampo.editor.shapes`,
`stampo.editor.tool.roundedRect`, `.polygon`, `.star`, `.bubble`,
`stampo.editor.tool.drawing.pen`, `.marker`. Shape tools remain inside Shapes;
there are no new inline buttons. “Украшение” in the older brief maps to Decor,
which opens the existing inspector.

## Artifacts and invariants

Each run writes `build/e2e/artifacts/<UTC timestamp>-<unique suffix>/` with a
passport, build/signature evidence, XCTest xcresult, summary and log. Each test
gets a unique subfolder for captures and step screenshots, also attached
to xcresult. Failures add a screenshot, AX tree and unified-log evidence.

Common tearDown checks that the process still runs at the expected path, no
new `~/Library/Logs/DiagnosticReports/Stampo*.ips` appeared, the full set of process
window ids and their on-screen flags returns to baseline, the four named log categories contain no error,
and an AX children query answers successfully within 2 seconds. Full window
inventories are saved before and after, including hidden windows. Before taking
the baseline, the harness opens and closes the panel once via real HID input
(with screenshots): AppKit creates it lazily and retains it after hiding. This
primes the ordinary cache without exempting subsequent hidden window leaks.
`Fixtures/log-allowlist.txt` accepts `message substring | specific reason`;
there are currently no exceptions. A failed log read or malformed allowlist
fails the scenario. The app terminates only after invariants are checked.

To add a scenario, subclass E2ETestCase, launch the app, record its window
baseline, perform a short flow through app/input helpers and attach each step.
Leave cleanup and invariant checks to the common tearDown. Do not depend on
user files, preferences, archive, network, initial cursor position or other apps.
Prove a scenario detects its historical bug by reversing only the app fix in a
temporary worktree; use a documented mutation if the brief specifies one.
Then require five consecutive passes. Fix the cause of any failure; after two
unsuccessful cause fixes, stop and ask the user. Do not repeat until green.
Quarantine, if authorized, must use XCTSkip with a reason/date and be listed here.

Current scenario: `S0/testPanelLifecycle` — launch, status item, global hotkey,
mode/delay/archive ids, close button, clean invariants. No quarantined scenarios.

## S0 behavior oracle

In a temporary worktree from the final implementation commit, comment out only
`panel.toggleAnimated(on: screen)` under `handleHotKey`, `case 1`, in
`NotchHoverController.swift`. Run `bash Scripts/run-e2e.sh --only S0 --seed 12345`.
The expected failure is `Panel cache warmup did not open the panel`. A missing
accessibility identifier alone is not the behavior oracle. Run the same command
without the mutation to establish the green control, then remove the worktree.
