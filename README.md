# Board

> # This project is 4-shots using GPT, I just find it useful

ask your AI agent to compile it for you, I havent checked a single line of code.

Native macOS camera notebook. The board fills the window.

## Collaborate with Claude or GPT

Board includes a local MCP server for **Claude (Desktop and Code)** and **GPT agents via Codex**. Your agent can also set it up for you. In Live view, turn on the camera, track the fully visible board and mark your sketch with a rectangle. Then ask:

> I have drawn a schema in top-left, put a better quality image upon it.

The agent can read that region and render a cleaner diagram over your sketch in the camera view, or add text, answers and questions. Images are sent only on demand, one requested crop at a time, keeping image context small without a continuous video feed. Diagram overlays use editable shapes and text.

## Use

Move to the right edge to reveal the controls. Pin keeps the panel open; × collapses it. The board keeps the full window in either state.

- **Camera** turns the preview on or off. Its arrow menu selects Mac or iPhone and contains Center Stage, Import and Recent versions.
- **Track** lets you mark four outer corners, including the board frame. Drag to adjust and confirm with ✓. Click Track while tracking to clear it; after loss, click it to recalibrate. Right-click for either action.
- **Annotate** lets you draw on the tracked board while the camera stays live. Enter a label and drag a rectangle. Click Annotate again to finish; the markings remain attached to the board and save automatically. **Rectangles** lets you edit or remove labels. In a saved version, **Live** saves that version’s edits and returns to the camera.
- **Copy** puts the whole board, annotations and visible AI overlays on the clipboard. Its arrow lets you copy just one named rectangle. Paste with **⌘V**. Either live copy saves a separate version and keeps the preview live.

Right-click **Copy** for **Copy folder path** or **Show folder**. The folder contains saved versions, annotations and the latest published image; a folder path is not a live feed. Image-paste support depends on the destination app.

Board does not contact assistants or inspect chats. Camera starts OFF. Originals and earlier exports remain unchanged.

## Tracking

The outline stays visible after calibration: solid while tracked, **red and dashed** at its last known position after loss. Copy is blocked while tracking is uncertain. The app keeps trying to recover the same board from its retained reference. Recalibrate manually if needed, or explicitly clear the selection to copy the full camera frame.

Select all four corners inside the image during calibration. During tracking, a corner may temporarily leave the image; the outline stays tracked where enough board detail remains visible. Copy requires the full board to be back in view. Writing and erasing are supported while enough of the original board detail remains visible across the selected area. Tracking follows movement relative to the camera: moving the Mac matters with its camera; with an iPhone, its movement matters instead.

OpenCV runs locally on one background queue, with late frames dropped. Analysis is capped at a 960-pixel longest edge: at most 8 Hz when still, 15 Hz while moving, and 4 Hz while lost. Each estimate matches SIFT features against the original, immutable calibration reference and verifies a projective transform with geometrically consistent matches spread across the board. It never replaces the reference with a guessed position. Apple Vision excludes detected people from the calibration reference; calibration requires that analysis to succeed. Each capture checks its exact frame before full-resolution perspective correction.

A blank or faint board may not provide enough distinctive detail. Include the frame and distributed writing when selecting corners. Temporary occlusion can recover against the original reference; erasing or covering all usable reference detail requires recalibration. These limits also apply to highly repetitive writing and severe blur. Live markings survive recalibration: choose the same physical board and corners to keep them aligned.

Center Stage pauses during board tracking and is restored on clear/stop unless changed externally. OFF or camera changes clear calibration; an interruption invalidates tracking.

## Versions

Data lives in `~/Library/Application Support/Board/`:

```
library.json           # versions and their annotation coordinates
live-annotations.json  # persistent markings in board coordinates
overlays.json          # editable AI text/diagrams with revisions
collaboration/         # bounded local MCP mailbox and transient region images
originals/             # immutable photographs
revisions/             # previous metadata
exports/               # immutable annotated PNGs
current.json           # latest published image and metadata
```

**Camera → Recent** opens saved versions. Live markings persist across restarts, camera changes and recalibration, independently of saved versions. Copy stores the current markings with that new version; later live edits do not change it. Back up the whole folder together. Corrupt/newer data and concurrent edits are preserved; failed writes produce an error. No automatic pruning.

Saved versions do not enter assistant context automatically. Only what you paste or explicitly ask an assistant to read is shared. Tracking keeps bounded memory and records no video. Camera OFF cannot retract images already pasted into chats.

## Build and checks

Requirements: **Apple Silicon, macOS 26+, Swift 6 and a macOS 26+ SDK** from Xcode or Command Line Tools. Build tooling uses Python 3.9+ (the version supplied with Command Line Tools works). No Homebrew, assistant account, API key, paid Apple Developer account or existing Board data is needed.

Install the developer tools with `xcode-select --install` if needed, then build from the source folder:

```sh
./scripts/build-app
open dist/Board.app
```

The first build downloads approximately 213 MB of public, checksum-pinned native dependencies. Subsequent builds use a verified local cache. The app bundles the 11 required libraries and their licenses; running the camera app needs neither Homebrew nor Python. The optional Claude/Codex MCP uses Python 3.9+. Camera access is requested when you turn it on.

The build selects a compatible installed SDK, including the SDK used to generate the icon. Set `BOARD_SDK_PATH` to choose a specific SDK. No developer-tool installation is modified. Release builds remove local source paths from debug records.

Validation commands:

```sh
./scripts/test-tracking
./scripts/test-library
./scripts/test-regions
./scripts/test-ink
python3 tests/check_annotation_model.py
python3 tests/check_dock_interactions.py
python3 tests/check_collaboration_service.py
python3 -m unittest discover -s tests -p 'test_*.py'
```

`build-app` first runs `scripts/prepare-opencv-runtime`. All OpenCV, TBB, OpenBLAS, GCC and OpenMP dependencies come from pinned official Homebrew bottles, staged under `.build/OpenCVRuntime`. It does not read a Homebrew installation or use private registry credentials. The public registry's anonymous download token stays in memory. The image-based collaboration test also needs Pillow (`python3 -m pip install Pillow` in a virtual environment); the app and remaining checks do not.

`scripts/test-tracking` handles the native module and runtime linkage. Pass `reference.png older.png latest.png [rawA.png rawB.png]` to include real-photo and Vision person-mask checks. `tests/NativeTrackerChecks.mm` covers real image pairs, geometry, excluded people, immutable-reference recovery and rejection of unrelated content. Swift checks cover tracking rates and recovery gates, image persistence, clipboard PNG/TIFF data, projective live markings and annotation persistence. Native tracking checks require the staged headers/libraries and their runtime search path. UI tests use isolated fixtures. Synthetic and saved-image tests do not establish robustness for every physical board or lighting condition.

The build handles mixed-version Command Line Tools without changing the installed toolchain. The app is ad-hoc signed, not notarized. The MIT license is in LICENSE.

To share source, run `python3 scripts/export-source.py`. It produces `dist/Board-source.zip` containing the source, tests, build scripts, license and a checksum manifest. It excludes build caches, compiled apps, logs, photographs, Board data and local client settings. The exporter rejects recognizable credential literals and personal home paths instead of silently packaging them. Keep `.build/` and `dist/` out of Git.

## Optional local collaboration MCP

### Claude setup

Choose **File → Connect Claude…** in Board. This connects the installed **Claude Desktop** and **Claude Code** clients to Board's bundled MCP. Restart Claude Desktop and start a new Claude Code session afterward. Repeating setup leaves an existing matching connection unchanged.

Setup adds only Board's local server, preserves existing client settings and keeps a private backup beside each changed Claude config. Board has no assistant login, API-key field or credential storage. If another server already uses the name `board`, setup leaves it untouched and reports the conflict. Python 3 must be installed for the MCP adapter; the native camera app itself does not need it.

The setup follows the [Claude Code user-scoped stdio configuration](https://code.claude.com/docs/en/mcp) and [Claude Desktop local MCP configuration](https://modelcontextprotocol.io/docs/develop/connect-local-servers). Its isolated tests run with `python3 -m unittest discover -s tests -p 'test_claude_setup.py'`.

### Tools

`scripts/board-mcp.py` exposes on-demand board regions and editable overlays through [MCP stdio](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports). It uses Python’s standard library and does not configure an assistant automatically. A local MCP client can launch it with `python3 /absolute/path/to/Board/scripts/board-mcp.py`; set `BOARD_LIBRARY` only to use a different Board data folder.

- `board_status` returns camera/tracking state, named regions and compact overlay summaries. Supply both the returned `revision` as `since_revision` and `instanceID` as `instance_id` to omit unchanged lists safely across app restarts.
- `board_read_region` reads one region ID from that status. Board must be open, its camera ON and tracking valid. The image defaults to a 1024-pixel longest edge; explicit requests allow 256–1600. Overlays are excluded unless requested.
- `board_list_overlays` returns summaries; supply `overlay_id` for one full editable payload.
- `board_put_overlay` creates text, an answer, a question or a diagram. Supply `overlay.frame` to place a small addition inside its parent region. Updating an existing ID requires its current `expected_revision`.
- `board_set_overlay` changes visibility or opacity with that same revision check.

Status and overlay lists contain no images. The server reads no continuous video, calls no model and sends no chat messages. Each region image is transient and only the requested crop is returned. A stale app heartbeat stops requests. A timed-out mutation may already have happened: inspect the overlay list before deliberately retrying. The server never retries a mutation automatically.

Run `python3 -m unittest discover -s tests -p 'test_board_mcp.py'` for isolated fake-IPC and stdio checks. These tests do not turn on a camera or alter assistant settings.

For Codex, register the bundled script with `codex mcp add board -- /absolute/path/to/python3 /Applications/Board.app/Contents/Resources/board-mcp.py` (adjust the app path to its installed location). The Python interpreter must remain installed; the camera app itself has no Python dependency. Reload MCP servers in Codex or open a new chat if the tools have not appeared yet. The same stdio command can be configured in another MCP client.

Draw and name a rectangle, then ask, for example: “Read Architecture and put a cleaner diagram over it.” Refresh it by asking Codex to reread that region without overlays and replace the same overlay ID using its latest revision. Text, questions and small node/arrow diagrams are supported; arbitrary HTML, scripts and remote images are not rendered.

Small additions have `frame: {x, y, width, height}`. All four values are normalized fractions of the parent region image, with the origin at its top-left corner. For example, `{x: 0.55, y: 0.65, width: 0.4, height: 0.2}` places a small card near the lower-right corner. Diagram node coordinates are local to that card. Without `frame`, an overlay keeps the previous whole-region behavior. Separate IDs allow several notes/diagrams in the same region; their placement is included in compact status summaries and saved copies. Automatic transparency responds only to movement within each addition's area.

For example: “Read my claim about LIKE in Current Problem / Solution proposed. Add a short answer next to it: correct, incorrect or needs qualification, with the reason.” The model reads the physical region, reasons about the claim and any required SQL dialect/context, then places its answer in available space. MCP supplies the image and display operations; it does not itself judge correctness. The model should say when handwriting is unclear. “Here” needs a visible landmark, a named rectangle or a described position; it is not a finger-pointing command. The raw region is read only on demand, without streaming video into the chat.

**Camera ▾ → AI annotations** lets you hide/show an annotation, change its opacity, or **Delete** it. **Clear all…** deletes the current live AI annotations after confirmation. Saved images keep their captured annotations. **Automatic transparency** is on by default: movement within a region temporarily lowers the opacity of its entire AI overlay. After the region settles, the overlay gradually returns to the opacity you chose. A person passing in front or writing on the board cannot leave a cutout in the diagram. Stationary writing and a stationary person become part of the next comparison rather than a permanent mask.

This is a motion aid, not extraction of individual marker strokes. New writing is visible through the temporarily transparent overlay; use **Transparent** to keep the physical board visible, or ask Codex to refresh the diagram from the region. Slow writing can be missed, and abrupt lighting or camera changes can briefly trigger transparency. Only reduced board frames are examined locally, at most twice per second, while a visible overlay has valid tracking. Nothing is sent to a model by this detector. Stopping or losing tracking, recalibrating, switching views or refreshing an overlay resets temporary activity; stale samples do not leave an overlay faded.

Copied versions retain their captured overlay/opacity state independently of later edits. Older saved versions containing spatial masks remain readable and unchanged; the live detector no longer creates those masks.

Finger/pen activation of virtual buttons is not enabled. Removal is currently through the native menu or an explicit assistant request.
