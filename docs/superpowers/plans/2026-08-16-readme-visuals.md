# README Visuals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce six privacy-safe bilingual README visuals, show local previews for approval, then publish only the approved assets and README references.

**Architecture:** Real Codex and tray screenshots provide evidence, while a deterministic SVG explains persistence. Raw captures stay in a thread-local preview directory, are cropped and irreversibly redacted before any generative image edit, and never enter Git. Approved assets are copied into `docs/assets`, referenced from the corresponding English or Chinese README, validated, committed, and pushed only after a second explicit user approval.

**Tech Stack:** Windows Computer Use capture, PowerShell/.NET image sanitization, built-in image generation/editing, deterministic SVG, GitHub-flavored Markdown, Git.

## Global Constraints

- Use the approved "real interface evidence" visual direction.
- Create three visuals per README: verified settings state, active tray menu, and persistence flow.
- English and Chinese assets must be structurally equivalent and use exact localized UI copy.
- Remove the custom Codex skin and replace it with neutral charcoal `#111318`.
- Never expose account names, device names, hostnames, paths, project names, task titles, pairing codes, ports, taskbar details, system tray details, notifications, or clocks.
- Crop or cover sensitive pixels with opaque replacement before any external image processing; never use blur or mosaic.
- Preview assets remain outside the Git repository and are not committed.
- Do not modify either README, replace existing assets, commit final visuals, or push until the user approves all previews.
- Preserve the unrelated untracked file `docs/superpowers/specs/2026-08-14-startup-recovery-and-shortcuts-design.md`.

---

## File Structure

Preview workspace, outside the repository:

- `C:/Users/33384/Documents/Codex/2026-07-28/wo/artifacts/readme-visuals/raw/` — raw target-window captures; never committed or externally transmitted.
- `C:/Users/33384/Documents/Codex/2026-07-28/wo/artifacts/readme-visuals/sanitized/` — locally cropped/redacted inputs safe for image editing.
- `C:/Users/33384/Documents/Codex/2026-07-28/wo/artifacts/readme-visuals/preview/` — six user-facing preview assets.
- `C:/Users/33384/Documents/Codex/2026-07-28/wo/artifacts/readme-visuals/Sanitize-ReadmeScreenshot.ps1` — temporary local sanitizer; not committed.

Repository files after preview approval:

- Create: `docs/assets/control-other-devices-active-en-US.png`
- Create: `docs/assets/control-other-devices-active-zh-CN.png`
- Replace: `docs/assets/tray-menu-en-US.png`
- Replace: `docs/assets/tray-menu-zh-CN.png`
- Create: `docs/assets/persistent-supervisor-flow-en-US.svg`
- Create: `docs/assets/persistent-supervisor-flow-zh-CN.svg`
- Modify: `README.md`
- Modify: `README.zh-CN.md`

---

### Task 1: Prepare the Isolated Preview Workspace

**Files:**
- Create outside repository: `C:/Users/33384/Documents/Codex/2026-07-28/wo/artifacts/readme-visuals/{raw,sanitized,preview}/`
- Create outside repository: `C:/Users/33384/Documents/Codex/2026-07-28/wo/artifacts/readme-visuals/Sanitize-ReadmeScreenshot.ps1`

**Interfaces:**
- Consumes: captured PNG path, crop rectangle, zero or more opaque redaction rectangles, output size, and background color.
- Produces: a metadata-free PNG on a `#111318` canvas, with no recoverable pixels outside the approved crop or below redaction rectangles.

- [ ] **Step 1: Create the preview directories outside Git**

Use PowerShell `New-Item -ItemType Directory -Force` with the three explicit directories above. Confirm `git status --short` in the repository is unchanged except for the already-known unrelated untracked file and this plan document.

- [ ] **Step 2: Create the local sanitizer**

Use `System.Drawing.Bitmap` and `System.Drawing.Graphics` to:

1. Decode the raw PNG.
2. Copy only the selected crop rectangle to a new bitmap.
3. Draw opaque `#1A1D21` rectangles over every named sensitive region.
4. Center the result on a `#111318` canvas at the requested output size.
5. Save a fresh PNG so original metadata and discarded pixels are absent.

The script accepts:

```powershell
param(
  [Parameter(Mandatory)][string]$InputPath,
  [Parameter(Mandatory)][string]$OutputPath,
  [Parameter(Mandatory)][int[]]$Crop,
  [int[][]]$Redactions = @(),
  [Parameter(Mandatory)][int[]]$Canvas,
  [string]$Background = '#111318'
)
```

Reject a crop or redaction rectangle with negative coordinates, zero dimensions, or bounds outside the source/cropped bitmap.

- [ ] **Step 3: Validate the sanitizer with a synthetic image**

Create a temporary bitmap containing a bright border and the literal text `PRIVATE-CANARY-7F3A`, crop/redact it, then verify:

- output dimensions equal the requested canvas;
- no source border pixels remain outside the crop;
- saving and reopening the PNG reports no inherited EXIF property items;
- the preview is manually inspected to confirm the canary region is fully opaque.

Delete the synthetic raw/output files after validation. Do not commit the temporary script or previews.

---

### Task 2: Capture and Sanitize the Verified Codex Settings State

**Files:**
- Create outside repository: `raw/control-other-devices-active-{en-US,zh-CN}.png`
- Create outside repository: `sanitized/control-other-devices-active-{en-US,zh-CN}.png`

**Interfaces:**
- Consumes: the live Codex Desktop Settings > Connections view.
- Produces: two privacy-safe 1200 x 900 PNG inputs containing only the relevant settings card on neutral charcoal.

- [ ] **Step 1: Record the current Codex language and open Connections**

Use Windows Computer Use against the Codex application window. Record the current language so it can be restored. Navigate through Settings to Connections without exposing another application window.

- [ ] **Step 2: Capture the English state**

Switch Codex to English if needed. Capture only the Codex target window. The intended crop includes the Connections heading, the `Control other devices` selector, and enough verified status to prove the feature is available. Exclude the title bar, sidebar, account area, task list, window chrome, taskbar, and system tray.

- [ ] **Step 3: Capture the Chinese state**

Switch Codex to Simplified Chinese. Repeat the same composition so the two versions are structurally equivalent. Restore the user's original Codex language after capture.

- [ ] **Step 4: Sanitize both captures locally**

Run `Sanitize-ReadmeScreenshot.ps1` before any image-generation call. Opaquely replace any visible real device/host/account data. Keep the actual tab labels, controls, and verified feature state. Output exactly 1200 x 900 PNGs.

- [ ] **Step 5: Inspect sanitized inputs**

View each at original resolution and confirm there is no skin, sidebar, task title, real device name, account data, path, pairing code, port, clock, notification, taskbar, or unrelated application. Reject and repeat capture/sanitization if any remain.

---

### Task 3: Produce the Polished Verified-State Previews

**Files:**
- Create outside repository: `preview/control-other-devices-active-en-US-preview.png`
- Create outside repository: `preview/control-other-devices-active-zh-CN-preview.png`

**Interfaces:**
- Consumes: the two sanitized settings PNGs from Task 2.
- Produces: two polished 1200 x 900 previews with unchanged, legible UI content.

- [ ] **Step 1: Run the built-in image edit for the English asset**

Use the sanitized English PNG as the edit target with this invariant-driven prompt:

```text
Use case: precise-object-edit
Asset type: GitHub README product screenshot
Primary request: Replace only the non-UI backdrop outside the Codex settings card with a perfectly flat neutral charcoal #111318 presentation background.
Constraints: Keep the Codex settings card, every control, icon, spacing relationship, and every readable UI character unchanged. Do not add text, devices, logos, shadows, reflections, gradients, watermarks, or decorative objects. Do not reveal or invent personal information.
Avoid: custom themes, wallpaper, taskbar, system tray, account details, device identifiers, blur, perspective distortion.
```

- [ ] **Step 2: Run the same edit for the Chinese asset**

Use the Chinese sanitized PNG and repeat the prompt with the same invariants. Keep all Chinese UI copy unchanged.

- [ ] **Step 3: Reject altered UI**

Compare each edited result with its sanitized input at 100%. If any UI text, icon, control, or spacing changed, discard that edit and use the deterministic sanitized input on the neutral canvas as the preview. Do not relax this criterion.

- [ ] **Step 4: Normalize and strip metadata**

Re-save accepted outputs through the local sanitizer without additional cropping or redaction so the preview remains 1200 x 900 and contains no inherited metadata.

---

### Task 4: Capture and Sanitize the Active Tray Menu

**Files:**
- Create outside repository: `raw/tray-menu-{en-US,zh-CN}.png`
- Create outside repository: `sanitized/tray-menu-{en-US,zh-CN}.png`
- Create outside repository: `preview/tray-menu-{en-US,zh-CN}-preview.png`

**Interfaces:**
- Consumes: the installed tray supervisor's verified active state and language menu.
- Produces: two tightly cropped 720 x 560 PNG previews containing only the project icon/menu.

- [ ] **Step 1: Record the tray language and confirm active state**

Open the project tray menu. Confirm the header/status indicates the current session is active/usable rather than waiting or blocked. Record the current language for restoration.

- [ ] **Step 2: Capture the English tray menu**

Select English, reopen the menu, and capture the target menu region. Crop out every unrelated tray icon, taskbar pixel, desktop pixel, notification, and clock.

- [ ] **Step 3: Capture the Chinese tray menu**

Select Chinese, reopen the menu, and repeat the same composition. Restore the user's original tray language afterward.

- [ ] **Step 4: Sanitize and frame both menus**

Use the sanitizer to place only the menu on a 720 x 560 neutral canvas. No image-generation call is required because the native menu text must remain pixel-accurate.

- [ ] **Step 5: Inspect both previews**

Confirm all menu edges are present, the project icon is visible, the active/green state is accurate, no line is clipped, and no unrelated desktop or tray content remains.

---

### Task 5: Build the Deterministic Bilingual Persistence Flow

**Files:**
- Create outside repository: `preview/persistent-supervisor-flow-en-US-preview.svg`
- Create outside repository: `preview/persistent-supervisor-flow-zh-CN-preview.svg`

**Interfaces:**
- Consumes: exact English and Chinese labels below.
- Produces: two accessible 1200 x 675 SVGs with identical geometry.

- [ ] **Step 1: Build the English SVG**

Use four horizontally connected rounded cards on `#111318`:

1. `Install once`
2. `Tray supervisor`
3. `Codex restarts or updates`
4. `Control other devices stays available`

Use `#1A1D21` cards, `#343A40` borders, `#F7F7F8` primary text, `#AEB4BC` supporting text, `#4EA1FF` arrows, and `#19C37D` for the final success state. Use simple inline SVG symbols for installer, tray shield, restart, and connected devices. Add `role="img"`, a descriptive `<title>`, and a `<desc>`.

- [ ] **Step 2: Build the Chinese SVG**

Reuse the exact geometry and replace only the labels:

1. `安装一次`
2. `托盘守护程序`
3. `Codex 重启或更新`
4. `“连接其他设备”保持可用`

Use a Windows-safe system font stack with `Segoe UI`, `Microsoft YaHei`, and `sans-serif`.

- [ ] **Step 3: Validate both SVGs**

Parse both as XML, confirm `viewBox="0 0 1200 675"`, verify no external URLs or embedded raster data, and render/inspect them at desktop and narrow/mobile widths. No label may overlap or clip.

---

### Task 6: Privacy and Visual QA, Then User Preview Gate

**Files:**
- Inspect: all six files under `preview/`

**Interfaces:**
- Consumes: six preview assets from Tasks 3–5.
- Produces: a user-visible preview set and a pass/fail privacy checklist; no repository modifications.

- [ ] **Step 1: Run structural checks**

Confirm:

- PNG dimensions are exactly 1200 x 900 or 720 x 560 as specified;
- PNG metadata does not contain source paths, software fields, comments, or personal text;
- SVGs are well-formed, contain no external references, and contain only approved labels;
- every filename ends in `-preview` and remains outside the Git repository.

- [ ] **Step 2: Perform a 100% visual privacy review**

Inspect every image edge and background. Explicitly check for account names, device names, hostnames, paths, tasks, project names, pairing data, ports, taskbar, system tray, notifications, clock, wallpaper, custom skin, and other-app content.

- [ ] **Step 3: Show all previews to the user**

Render all six assets inline with concise labels. State that README and repository assets remain unchanged. Ask the user to approve or request revisions.

- [ ] **Step 4: Stop at the approval gate**

Do not continue to Task 7 until the user explicitly approves the previews.

---

### Task 7: Promote Approved Assets and Update Both READMEs

**Files:**
- Create/replace: the six repository assets listed in File Structure.
- Modify: `README.md`
- Modify: `README.zh-CN.md`

**Interfaces:**
- Consumes: user-approved preview files.
- Produces: final repository assets and bilingual Markdown references.

- [ ] **Step 1: Copy approved assets without the `-preview` suffix**

Copy only the six approved previews to their exact `docs/assets` destinations. Do not copy raw or sanitized intermediates.

- [ ] **Step 2: Update the English README**

Add the English verified-state image after Quick start, the English flow after Everyday use, and the English tray image directly under Tray menu. Use concise alt text and this caption:

```text
Example interface; account, device, and environment details have been removed.
```

- [ ] **Step 3: Update the Chinese README**

Add the corresponding Chinese assets in the same structural positions. Use concise Chinese alt text and this caption:

```text
示例界面；账号、设备和环境信息均已移除。
```

- [ ] **Step 4: Validate Markdown and asset paths**

Check that all six relative paths resolve, neither README references a preview/raw file, and both documents remain valid UTF-8. Render at a narrow width and confirm there is no horizontal overflow.

- [ ] **Step 5: Review the final diff**

Run `git diff --check`, inspect `git diff -- README.md README.zh-CN.md`, and verify `git status --short`. Ensure the unrelated untracked startup-recovery design remains unstaged.

- [ ] **Step 6: Run repository validation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Validate.ps1 -SkipInstalledPackageCheck
```

Expected: all repository validation suites pass.

- [ ] **Step 7: Commit the final visual refresh**

Stage only the six approved assets and the two README files, then commit:

```text
docs: add bilingual README visuals
```

- [ ] **Step 8: Push only after explicit user approval**

Push `main` to `origin` only after the user has reviewed the final README diff and explicitly authorizes the upload.
