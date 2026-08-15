# README Visuals Design

## Goal

Make the English and Chinese READMEs easier to trust and scan by adding three
compact visuals per language: a verified Codex success state, the supervisor
tray menu, and a simple persistence flow. The visuals must not expose any
personal data or the user's custom Codex skin.

No README or remote repository update happens until the user approves the
generated preview assets.

## Visual Set

### 1. Verified `Control other devices` state

- Source: a real Codex Desktop Settings > Connections view.
- Composition: only the relevant settings content card; exclude the title bar,
  sidebar, task list, account area, window chrome, taskbar, and system tray.
- State: show `Control other devices` as available and the supervisor as active.
- Device labels: replace real device names with generic examples such as
  `Windows PC` and `Mobile device` before any external image processing.
- Background: replace the custom skin with a flat neutral charcoal (`#111318`).
- Output: PNG, approximately 1200 x 900, optimized for GitHub mobile display.

Final candidates:

- `docs/assets/control-other-devices-active-en-US.png`
- `docs/assets/control-other-devices-active-zh-CN.png`

### 2. Active tray supervisor menu

- Source: a real project tray menu in a verified green/active state.
- Composition: keep only the project icon and menu; exclude every other tray
  icon, desktop element, notification, clock, and taskbar region.
- Background: transparent or the same neutral charcoal frame.
- Output: tightly cropped PNG, approximately 720 x 560.
- These assets replace the current menu images only after preview approval.

Final candidates:

- `docs/assets/tray-menu-en-US.png`
- `docs/assets/tray-menu-zh-CN.png`

### 3. Persistent integration flow

- Content: `Install once` -> `Tray supervisor` -> `Codex restarts or updates`
  -> `Control other devices stays available`.
- Style: compact, high-contrast, neutral dark theme with simple Windows,
  supervisor, restart/update, and device-connection symbols.
- Implementation: deterministic SVG so labels remain sharp and localization is
  exact; no personal screenshots are used.
- Output: 1200 x 675 SVG, with a separate localized version for each README.

Final candidates:

- `docs/assets/persistent-supervisor-flow-en-US.svg`
- `docs/assets/persistent-supervisor-flow-zh-CN.svg`

## Privacy Pipeline

1. Capture only the named Codex or tray window/region.
2. Crop away unrelated UI before saving a working image.
3. Apply irreversible opaque replacement to account names, device names,
   hostnames, paths, project names, task titles, pairing codes, ports, and other
   identifiers.
4. Strip PNG metadata before any generative image edit.
5. If image editing is used to replace the skin background, send only the
   already-cropped and already-redacted image. Keep the actual Codex UI content
   unchanged and reject any result with altered or unreadable UI text.
6. Inspect every final at 100% scale, including edges, shadows, and transparent
   pixels. Verify that no account, device, workspace, path, taskbar, clock,
   notification, or custom-skin detail remains.

Real values must never be blurred. They are cropped out or replaced with solid
generic content so OCR or enhancement cannot recover them.

## README Placement

### `README.md`

- Verified-state image immediately after Quick start.
- English persistence flow immediately after Everyday use.
- English tray image directly under Tray menu.

### `README.zh-CN.md`

- Chinese verified-state image immediately after 快速开始.
- Chinese persistence flow immediately after 日常使用.
- Chinese tray image directly under 托盘菜单.

Each image receives a short localized alt text and a one-sentence caption that
states that account, device, and environment information was removed.

## Preview and Approval Boundary

- Preview files use a `-preview` suffix and are not referenced by either README.
- The user receives all six previews before any README change, asset replacement,
  commit containing the final visuals, or remote push.
- Rejected previews are revised locally; they are not published in Git history.

## Validation

- Both Markdown files render with three visuals and no horizontal overflow at a
  narrow/mobile width.
- English and Chinese text matches the corresponding README.
- UI text is readable at GitHub's normal content width.
- Screenshot PNGs contain no metadata beyond required image structure.
- Repository status review confirms that unrelated existing files are not staged.
- Final links use relative `docs/assets/...` paths and work from GitHub.

## Non-goals

- No full-desktop screenshot.
- No installer wizard or PowerShell tutorial image.
- No version number embedded in artwork.
- No claim that this is an official OpenAI implementation.
- No modification to application code, installer behavior, or runtime behavior.
