# TUI Design

This document defines the presentation and interaction contract for the inzone-linux terminal interface. It records the current design, the reasons behind it, and the checks required when changing it. [README.md](README.md) covers installation and end-user commands.

## Design direction

The interface combines Apple's emphasis on hierarchy, alignment, and restrained visual emphasis with Samsung One UI's grouped settings, separation of information from interaction, and concise wording. These principles are adapted to terminal cells, not reproduced as native Apple or Samsung components.

| Reference | Application in this project |
| --- | --- |
| [Apple HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | Separate navigation, content, and actions. Align related elements and preserve useful space between groups. |
| [Apple HIG: Color](https://developer.apple.com/design/human-interface-guidelines/color) and [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) | Reserve prominent styling for the main action. Distinguish selection, editable values, destructive actions, and unavailable controls. Provide press feedback. |
| [One UI overview](https://developer.samsung.com/one-ui/index.html) and [Lists](https://developer.samsung.com/one-ui/comp/list.html) | Place status information above settings and frequent actions below them. Group settings by task, with short names and controls beside their values. |
| [Samsung UX writing](https://developer.samsung.com/design-system/cs) and [Simple and human](https://developer.samsung.com/one-ui/writing/simple-and-human.html) | Use one consistent voice. Describe the action or result directly, and provide recovery instructions when an actual problem occurs. |

The design priorities are:

1. Make the next useful action clear.
2. Keep information visible without competing with controls.
3. Preserve keyboard operation while supporting pointer and touch input.
4. Preserve draft changes according to each screen's editing contract.
5. Validate the rendered interface, not only the view definitions.

## Visual hierarchy

Use a neutral graphite background, readable text, and limited blue emphasis. A screen should normally have one prominent action, such as Apply, Save & Apply, or Add rule. Secondary actions must remain visible without appearing equally important.

- Use bold text and neutral shading for selection.
- Use blue backgrounds for primary actions and blue text for editable value controls.
- Use muted text for descriptions, shortcuts, and secondary information.
- Use red for destructive actions or actual error conditions.
- Keep read-only settings neutral. An enabled setting does not automatically need a bright color.
- Keep the selected profile's details in the main content area; do not repeat them in the sidebar.

Do not add decorative brackets, `>` selection prefixes, profile ordinal numbers, or `Active` labels. These duplicate the established presentation. Meaningful values and state indicators remain valid, including frequencies, percentages, rule priorities, and the `*` marker for an unsaved device value. Never remove these characters from user-provided text merely because they also resemble decoration.

### Color tokens

Use [TerminalTheme](Sources/InzoneTUI/TerminalComponents.swift) rather than introducing local RGB literals. The source remains authoritative when the palette changes.

| Token | Current RGB hex | Purpose |
| --- | --- | --- |
| `background` | `#121214` | Main canvas and plain controls |
| `surface` | `#1A1A1C` | Subtle grouping and secondary controls |
| `raised` | `#2C2C2E` | Selection and hover |
| `text` | `#F2F2F7` | Primary readable content |
| `muted` | `#9B9BA2` | Supporting content and unavailable values |
| `accent` | `#377DEB` | Primary actions and editable values |
| `pressed` | `#404044` | Press feedback for neutral controls |
| `accentPressed` | `#2863C3` | Press feedback for primary actions |
| `danger` | `#FF7474` | Destructive actions and errors |

These are application colors, not native dynamic system colors. Test legibility in the actual terminal and font configuration. Do not rely on hue alone: selection also changes weight, toggles retain textual values, and pending device changes retain their marker.

## Window structure and spacing

The supported minimum viewport is **72 columns × 24 rows**. Smaller windows display a resize message and an exit control.

| Region or constraint | Size |
| --- | --- |
| Outer horizontal margin | 1 column on each side |
| Header | 3 rows |
| Space below header | 1 row |
| Main content | Terminal height minus 7 rows |
| Space above footer | 1 row |
| Footer | 2 rows |
| Touch sidebar breakpoint | 110 columns |
| Sidebar width | 28 columns |
| Sidebar-to-content gap | 2 columns |

The header shows the current screen and layout switch. The main touch profile screen also exposes Quit in the header. The footer's first row shows status or an actionable error; its second row shows context-specific keyboard guidance.

Header and footer positions must remain fixed while navigating, editing, or resizing. The content region includes the sidebar and must fit between the two blank separation rows. Do not use those rows as overflow space.

Use [TerminalEqualColumns](Sources/InzoneTUI/TerminalLayout.swift) for equal-width groups. It distributes integer-cell remainders across columns instead of leaving an uneven trailing gap. Children must accept the proposed width so their visual and interactive frames agree.

### Density and target sizes

| Control | Current height |
| --- | --- |
| Primary and ordinary touch actions | 3 rows |
| Profile rows below 30 terminal rows | 2 rows |
| Profile rows at 30 terminal rows or taller | 3 rows |
| Device category tabs and setting rows | 3 rows, with vertically centered labels |
| Compact value controls | 2 rows |
| Compact-layout action controls | 1 row |

Common action labels have 2 columns of horizontal padding. Their entire frame is interactive, including blank padded cells.

Cell dimensions do not guarantee a physical touch-target size. Touch operation depends on the terminal translating taps into primary-pointer events, and text entry depends on a physical or system onscreen keyboard. Native multitouch, Liquid Glass, haptics, and Apple point-based sizing are not implemented.

## Navigation and screen composition

The default Touch layout and the optional Compact layout share the shell, model, and commands. Their content density differs. Layout choice lasts for the current session.

### Profiles

The default layout uses a profile list beside a detail column. The detail column contains the selected profile's description and sound-processing values. Selection is a preview; it does not mean that the profile has been applied.

Keep Device and Automation directly reachable from the lower action area. Controls opens sound settings, EQ, and presets. Device & apps provides additional destinations, including personalization import. Secondary navigation should not force repeated trips through unrelated menus.

### Sound controls and EQ

Sound controls place a short setting name on the left and its editable value on the right. Unsupported controls are unavailable rather than appearing to work.

The Touch EQ screen uses a bipolar ten-band bar graph with a labeled 0 dB baseline and a fixed −12 to +12 dB range. The bars represent configured band gains, not the calculated frequency response of the audio filters. Frequency labels identify every band; the selected band also has an exact numeric readout.

Tapping a bar or frequency selects its band without changing gain. A vertical drag that starts inside the plot adjusts the original band, with values clamped to the supported range. A drag remains tied to its original band even when the pointer moves horizontally or the viewport resizes. Frequency-label drags do not edit gain.

Graph resolution depends on available terminal rows. Keep the ±1 dB buttons and keyboard adjustments for precise changes. Compact previous/next buttons (`‹` and `›`) remain beside the readout. Put cancellation on the leading side and the primary save action on the trailing side. Compact mode retains the numeric EQ list.

### Device

Keep connection and battery information in the compact upper overview. The settings area uses task-oriented tabs:

| Tab | Contents |
| --- | --- |
| Noise | Noise control, ambient level, and voice focus |
| Sound | Game/chat balance and game/chat output volumes |
| Mic | Sidetone, microphone volume and mute, and microphone monitoring |
| System | Button-cycle settings, startup behavior, auto power off, and voice guidance |
| Info | Connection details, firmware versions, and setting scope |

Each row places the setting name on the left and its controls on the right. Binary values toggle by tapping the value. Other values use adjacent minus/plus actions. Long sections expose Previous and More settings; reaching a setting must not depend on a mouse wheel.

Tap a category or swipe horizontally across the category strip or settings area to change sections. Left moves forward and right moves back by one section; the first and last sections do not wrap. Ignore short or predominantly vertical gestures. Section swipes take priority over setting controls, so swiping across a value must not toggle or adjust it. Draft changes survive both tap and swipe navigation.

Back, Discard, Refresh, and Apply remain in the lower action area. Microphone monitoring is available in Mic, and its stop control remains available while monitoring is running. Do not restore the previous layout of large status cards above a single visible setting and global previous/next adjustment buttons.

Compact mode retains a linear device list with text status. Category tabs and inline adjustment controls belong to Touch mode.

### Automation and input forms

An empty automation screen explains what the user can do and presents Add rule. Do not show navigation or deletion controls for a nonexistent list. When rules exist, keep list navigation distinct from editing and service controls.

Forms show their specific field instruction, the input, and cancellation/continuation actions. Use Continue for intermediate steps and Save for the final step. Validation feedback belongs in the status area without erasing entered text.

## Editing contracts

| Interaction | Persistence and commit behavior |
| --- | --- |
| Select a profile or preset | Changes the selection only; Apply performs the operation. |
| Change a profile DSP option | Applies immediately. The controls screen states this behavior. |
| Edit EQ | Changes an in-memory draft. Reset all changes the draft; Save & Apply commits it; Cancel discards it. |
| Adjust device settings | Stores per-setting drafts keyed by the setting name. Selection, tab changes, refresh, Back, and workspace navigation preserve them. |
| Apply device settings | Writes and verifies settings sequentially. This is not an atomic transaction. Readback clears confirmed values; unconfirmed drafts remain after failures or loss of availability. |
| Discard device changes | Clears drafts without writing settings. |
| Exit the application | Ends the session; drafts are not persisted. There is no universal quit-confirmation dialog. |

Never report a draft as saved merely because a control changed visually. Missing device data must not be presented as zero, Off, or a successful update. Preserve distinctions between charging, running on battery, charge error, unknown data, and disconnection.

The workspace sidebar is unavailable while a prompt, EQ editor, or preset screen is open, or an operation is busy. This is not a universal navigation lock: device drafts deliberately survive navigation. Escape returns from Device & apps to Controls, then from Controls to Profiles.

## Interaction and feedback

Reuse [TerminalAction](Sources/InzoneTUI/TerminalComponents.swift) for action controls.

| Role | Presentation |
| --- | --- |
| `normal` | Neutral secondary action |
| `plain` | Low-emphasis navigation or toolbar action |
| `value` | Editable value with blue text |
| `primary` | Blue-filled main action |
| `destructive` | Red action label |

Common action controls provide hover and press feedback. They capture a primary-pointer press and activate only when released inside the same control. Releasing outside cancels activation. Disabling or removing a control must clear transient interaction state. Row selection uses separate tap handlers. The EQ graph continuously updates a draft during captured vertical dragging; releasing outside the plot retains the clamped draft value rather than acting like button cancellation.

While a mutation is running, suppress conflicting edits and show progress in the footer. Keep stopping an active microphone monitor available. Do not infer authorization to apply settings from hover, selection, or navigation.

## Wording

- Use short, specific action labels: Apply, Discard, Refresh, Continue, Save, and Add rule.
- Describe results in user terms, such as “Device settings updated.”
- Put technical diagnostics in the relevant status or information area, not inside every setting row.
- Show recovery instructions for an actual problem; avoid permanent speculative warnings.
- Preserve units and useful context, including percentages, dB, minutes, and the balance midpoint.
- Keep technical artifacts and UI strings neutral. Do not introduce assistant names or conversational persona language.
- Sanitize terminal control characters in untrusted labels, paths, and errors before rendering them.

## Implementation boundaries

| Source | Responsibility |
| --- | --- |
| [InzoneTUI.swift](Sources/InzoneTUI/InzoneTUI.swift) | Shared shell, screens, navigation, observable model, and worker coordination |
| [TerminalComponents.swift](Sources/InzoneTUI/TerminalComponents.swift) | Semantic palette, action roles, and common pointer feedback |
| [TerminalLayout.swift](Sources/InzoneTUI/TerminalLayout.swift) | Equal-column measurement and placement |
| [EqualizerGraph.swift](Sources/InzoneTUI/EqualizerGraph.swift) | Band-gain graph, cell-to-gain mapping, and captured drag editing |
| [ProfileSummaryView.swift](Sources/InzoneTUI/ProfileSummaryView.swift) | Profile summary and detail presentation |
| [DeviceControlsView.swift](Sources/InzoneTUI/DeviceControlsView.swift) | Device categories and compact status overview |
| [DeviceStatusView.swift](Sources/InzoneTUI/DeviceStatusView.swift) | Typed device status and the standalone detailed status-card renderer |

Presentation changes must not bypass controller validation, device readback, or busy-state protection. New external production dependencies require explicit approval. The detailed status-card renderer is not the default device screen; use the compact overview in the task-oriented layout.

## Verification and review

Run the UI test target and whitespace validation:

```sh
swift test --filter InzoneTUITests
git diff --check
```

Export synthetic, hardware-independent previews and render the actual ANSI output:

```sh
INZONE_TUI_PREVIEW_DIRECTORY=/tmp/inzone-design-preview swift test --filter VisualPreviewTests
python3 tools/render_tui_snapshot.py /tmp/inzone-design-preview /tmp/inzone-design-preview-png
```

The optional PNG renderer requires Pillow and DejaVu Sans Mono fonts. These are not runtime dependencies. Use a Python interpreter that provides Pillow.

Before accepting a visual or interaction change:

- Inspect 72×24 and 120×36 renders, both density modes, and relevant breakpoint boundaries.
- Verify header/footer positions, both blank separation rows, readable labels, and reachable actions.
- Inspect populated, empty, unavailable, selected, pending, and busy states relevant to the change.
- Exercise taps on padded cells, press/release cancellation, and keyboard operation after pointer use.
- Confirm that resizing and navigation preserve the screen's editing contract.
- Check device draft retention, explicit discard, bounds, and partial-failure behavior when modifying setting flows.
- Review screenshots alongside automated tests; text presence alone does not establish visual quality.
- State which checks were actually run. Synthetic previews and PTY tests do not establish physical touch usability, real-device writes, or installation success.

Human review remains required for AI-assisted changes. Update this document when changing a design contract, rather than allowing the source, screenshots, and guidance to describe different interfaces.
