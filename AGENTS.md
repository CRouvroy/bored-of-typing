# Board

Native macOS camera/annotation app. Keep Desk untouched. Read README.md before changing capture, version storage or delivery semantics.

## Design

The user's explicit design requirements from Desk and this app take precedence over generic UI templates:

- No slogans, subtitle strips, footer, permanent explanatory paragraphs, tiny gray labels, uppercase micro-headings, or dot-separated status strings.
- No repeated dates, technical paths or IDs in the main UI. Use tooltips or contextual details where needed.
- Photograph first. Use Desk's right floating proximity panel with a compact resting rail; the canvas must not reserve space for a top toolbar or annotation strip. Preserve stable layout, pin/collapse controls, restrained icons, borderless native menus, and normal readable system typography.
- Keep a few direct actions. Advanced choices belong in contextual popovers. Do not add a button or label to compensate for an unclear interaction.
- Errors and real action results must remain clear and actionable. Empty states contain no fabricated research.
- Small AI notes/answers/diagrams use an explicit normalized frame inside a named region. Preserve surrounding board content, existing additions and readable typography; do not add main-window controls or explanatory strips for this capability. Unspecified frames retain legacy whole-region rendering. MCP transports content and placement, while the assistant reasons about user claims and acknowledges ambiguous handwriting or location.

## Behavior

- Camera starts OFF. No background capture, automatic provider messages, or live model calls in tests.
- Originals and prior exports are immutable. Preserve corrupt/newer data. Never repair data by deleting a library.
- Clipboard-first UI only: camera, tracking, annotation and Copy. No composer, provider selector, chat discovery or automatic sending. Copy and Annotate preserve the live preview. Live markings use normalized board coordinates, move with the projective board geometry, and persist in live-annotations.json independently of saved versions. Copy snapshots those markings; later live edits never alter that version. Saved versions belong in a small menu.
- Clipboard copy is not proof of paste or assistant ingestion.
- Do not touch provider credentials, rewrite chat databases or silently resume another process's session.
- The user explicitly requested local collaboration MCP: it may read one named live region on demand and edit bounded text/diagram overlays with revision checks. Never turn on the camera from MCP, poll video into assistant context, execute overlay code or automatically message a provider. Local interaction detection may temporarily reduce an entire overlay's opacity, then restore it after motion settles; do not generate or accumulate spatial holes from people, old writing or uncertain changes. Keep detection local and bounded and reset temporary activity when valid samples stop. Do not claim individual marker-stroke recognition. Copied versions preserve raw originals and separate overlay/mask metadata, including immutable older masks. Global integrations require a user request (Codex and Claude setup are authorized for this task).
- Board contains no assistant login, account discovery, credential storage or provider session management. Claude setup configures only Board's local stdio MCP entry and preserves unrelated client configuration. Never copy provider credentials into Board data or app resources, or restore the removed legacy sending bridge.
- Calibrate against the exact frozen frame shown to the user. Track on a serial background queue with bounded resolution/rate; keep updates out of the chat/history observation path. Rectify a capture only with a valid result for that same frame. Uncertain tracking must block capture until fresh verified tracking resumes or the user explicitly clears calibration. Keep the last outline visible, distinguish stale geometry, and allow bounded same-board recovery after transient failures.
- The native OpenCV tracker matches immutable calibration SIFT features directly to each analyzed frame. Never update its reference from an estimated pose. Analysis has a maximum 960-pixel edge and caps of 8 Hz still, 15 Hz moving, and 4 Hz lost; do not add a 30 Hz mode. Apple Vision person exclusion must succeed when seeding. Preserve clockwise TL/TR/BR/BL identity in top-left coordinates across native tracking and live annotations.
- Board contents change during research. Tracking checks must tolerate writing/erasing while enough original detail remains distributed across the board. Blank/faint boards and fully erased or covered reference features require recalibration; do not claim arbitrary content changes work. Center Stage follows people and is paused during board tracking; never silently enable a conflicting framing mode.

## Validation

The current app targets Apple Silicon/macOS 26+. Build with scripts/build-app; it prepares and bundles the pinned native runtime and licenses without a global Homebrew installation or upgrade. Keep runtime dependencies self-contained. Run the native real-image tracker checks, Swift persistence/raster/tracking/live-annotation checks and applicable MCP/setup tests when changing those components. Standalone tracking builds must link BoardNativeTracker and the staged OpenCV runtime. Inspect changed native UI. Use an isolated BOARD_DATA_DIR for test fixtures. Do not present mocked sending or camera enumeration as live delivery/capture validation.
