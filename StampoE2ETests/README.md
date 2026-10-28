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
them. Native Settings toolbar buttons receive AX identifiers only in DEBUG
with -StampoE2E; sidebar rows use SwiftUI identifiers. P6 checks all five toolbar
ids at runtime. Editor/archive ids remain source mappings beyond S0/S0b.

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
window ids and their on-screen flags returns to baseline, the four named log categories contain no error or fault,
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

`S0/testPanelLifecycle` checks launch, status, the global hotkey, required panel
controls, close and clean invariants. `S0b` covers fixture pixels and the editor
hook. `PanelE2ETests` has six methods: open/close cycles, panel menus, HID Esc menu closure, pointer-dependent Tab, status Settings, and status Quit. No skips or
quarantined scenarios are enabled.

## S0 behavior oracle

In a temporary worktree from the final implementation commit, comment out only
`panel.toggleAnimated(on: screen)` under `handleHotKey`, `case 1`, in
`NotchHoverController.swift`. Run `bash Scripts/run-e2e.sh --only S0 --seed 12345`.
The expected failure is `Panel cache warmup did not open the panel`. A missing
accessibility identifier alone is not the behavior oracle. Run the same command
without the mutation to establish the green control, then remove the worktree.

## Repeated window leak oracle

Retain a new borderless 10×10 NSWindow at the start of every showAnimated call
in a temporary worktree. The warmed baseline contains the first allocation;
the second opening must fail with `E2E full window set did not return to baseline`.
The review mutation detected two hidden windows becoming three; removing it
returned S0 to green. Full inventories and the patch are retained in local artifacts.

## Error log oracle

Insert `Log.panel.error("E2E mutation: panel shown")` at the start of
showAnimated in a temporary worktree, importing OSLog there. S0 must finish its
steps and fail in teardown with `Unexpected E2E errors` and that exact message.
The review mutation was red and its unmodified control green. The same log
predicate covers error and fault; exceptions require an explicit allowlist reason.

Archive cell identifiers intentionally follow array positions (`stampo.archive.cell.<index>`); adding a capture shifts the existing indices.

Panel cache warmup proves that repeated opening leaves no extra window. It does not prove that the first opening never creates a permanent extra window; a pre-first-open window-count scenario would cover that blind spot and is outside this step.

S0b covers only the primary display. Keep the fixture unobstructed by notifications, panels or other windows: its pixels are sampled from a screen screenshot, not a window capture.


`PanelE2ETests` adds twenty panel open/close cycles, mode/delay/more menu
checks, pointer-dependent Tab delivery, and status-menu Settings/Quit paths.
`stampo.e2e.fixture.keys` is a zero-sized, AX-only child whose value counts
fixture `keyDown` deliveries; it exists only in the DEBUG E2E fixture.
Settings/Quit launch with the fixture to establish AppKit's key-window
activation cache before recording the full window baseline. No window ids or
onScreen flags are exempted. Status-menu opening checks nonempty menu-item
frames: hidden NSMenu items also satisfy `exists` on macOS.

Panel modes and delays reset to the E2E defaults on every panel reveal.
P2 verifies that reset; it does not require a transient choice to persist.
The late-hide race found by P1 is fixed in main by d956594, which is also a
P1 oracle. Do not add a pause between closing and reopening the panel.


`testMoreMenuClosesOnEsc` is ordinary HID regression coverage after the
045b2ff fix in main (PR #53). Reversing that app fix is its oracle. The runner
rejects expected failures as well as unexpected failures, skips and zero tests.

For the More → Settings path, current settingsTapped leaves the panel visible.
After closing Settings, the test first compares More while the panel remains
visible and verifies the full window set against an immutable phase snapshot.
It then hides the retained panel through the HID hotkey, verifies the original
closed-panel baseline, reopens and compares More again. The pointer never
crosses More during this normalization.

Menu selections use a single held HID gesture: press the popup, drag to its
item while NSMenu tracks, and release there. This targets the lost release
and pointer exit from daf3bad/fabf326. The old afterClose results used an inverted PNG decoder and do not prove
release-state sensitivity; see the oracle limitations below.


## Известные ограничения оракулов

`daf3bad` и `fabf326`: прежний вывод «не воспроизводится на этой macOS»
был принят до обнаружения перевёрнутых Y-строк в Files.Bitmap (обновление 7).
Те сравнения читали другую область экрана: они не доказывают отсутствие
залипшей подсветки. Старые зелёные логи сохранены в stage3-final/oracles*,
stage3-update4/oracles/p2-more; переинтерпретировать их как красные нельзя.
Новых жестов и повторов этих исторических мутаций после открытия причины
не выполнялось. M3 и остальные пиксельные проверки предстоят с исправленным
decoder; чувствительность P2 ещё не доказана.

`1f1e69f` — оракул снят: его исправление откатили в bc68d99. Проверки
верхнего края остаются свойствами. Явный native safe-area inset, если
используется как fault injection, является собственной, не исторической
мутацией. Оракул гонки P1 — d956594.


## Quit exit evidence

P6 Quit records the target PID before choosing Quit. After it disappears,
teardown requires runningboardd's termination report for that exact app PID
and this launch: `(0, 0, 0)`. Measured on macOS 27.0.1: normal Quit gives
`(0, 0, 0)`, abort gives `(2, 6, 6)`. Child XPC-service exits are excluded by
identity. A missing system report fails after a bounded 5 s wait; a nonzero
termination report fails immediately. Raw JSON and the selected exit message
are attached. The ordinary crash-report invariant remains enabled.


## P1 cycle and outside-click coverage

`testOpenCloseCycles` runs without a fixture: twenty opener/closer pairs,
with escape/button/hotkey/notch closures and no pause before reopening.
Both notch-closing pairs recur at least twice. Frontmost application ids
are logged to test the activation hypothesis behind the late-hide oracle.

`testOutsideClickCloses` owns the fixture: four cycles, two each from hotkey
and notch. Each outside click uses the current AX center of
`stampo.e2e.fixture`, outside the panel. The panel must disappear, the full
window set return to baseline and the fixture retain its frame.

Закрытие кликом вне панели проверено только через локальный монитор (клик
в окно-образец Stampo). Клик в окно другой программы (глобальный монитор)
автоматическим тестом не покрыт; проверяется вручную.
Both monitors use `handleGlobalLeftMouseDown`.


## AX query failures

Native AX reads throw on a failed root children response, messaging error or
2000-node traversal limit. Unsupported optional leaf attributes remain absent.
`waitUntil` propagates a thrown query; it cannot turn that into an ordinary
missing element. `testAXQueryRejectsTerminatedProcess` terminates only its owned
copy, then requires liveElement to throw. That explicit probe skips process/
window/AX liveness after termination; crash, log and input checks still run.


Esc coverage checks both sides of menu tracking: first HID Esc closes More
while preserving the panel; one MainActor delivery turn (100 ms) is allowed
for didEndTracking to restore the hotkey, then a single second HID Esc must
close the panel and restore the full window baseline. Esc is never retried.


Status menu coverage requires the HID left click. A failed click saves the
snapshot and AX tree and fails; no right-click or AXPress fallback is used.
Input cleanup still checks and releases both mouse buttons independently.


## Status item visibility before a HID click

openStatusMenu saves the owned process's CGWindowList inventory and a screen
PNG before clicking. The AX frame must lie on the primary display. Its central
**14×18 pt** region is sampled in sRGB; the median RGB of top/bottom **1 pt**
strips of the full AX frame estimates the local background. A pixel counts as
foreground when max absolute RGB-channel difference is **≥80**. At least
**5%** of the central pixels must be foreground. The narrow center excludes a
neighboring chevron overlapping the right edge of the hidden item's frame.
It is a foreground check, not rabbit-shape recognition; another glyph in the
same center could produce a false positive.

At Retina ×2, the sample is 1008 pixels. Ten drawn reference frames from
20261028T164830Z-N1Rfnh give **288–297/1008 (28.57–29.46%)**; the hidden frame
from 20261028T190149Z-r1HSCP gives **0/1008**, background RGB **32,32,32** in
both. The exact runtime helper classifies all eleven saved cases correctly.
Measurements, crops and source references are in build/e2e/stage3-update7/.
No interface golden PNGs are committed. CG window data is diagnostic: the old
inventories contain no separate window matching the AX status frame in either
case, so window onScreen/alpha alone cannot establish that it was drawn.

A failed visibility check saves the frame, measurement and window list, fails
with `Status item is not drawn at its Accessibility frame ...`, and sends **no
click**. After a pass, the frame must still match and only its verified center
receives one HID left click. The 1 s menu timeout and absence of fallbacks are
unchanged; there is no new script preflight or environment adjustment.

The PNG decoder now preserves top-left row order. BitmapTests covers four
asymmetric corner colors; the old decoder read the top row as the bottom row.
The original red/blue fixture is vertically symmetric and did not detect this.
Offline verification passes, but the UI runner failed before executing the new
XCTest (`Timed out while enabling automation mode`); a live guard run and final
Settings×5/Quit×5 still require a working automation session.
