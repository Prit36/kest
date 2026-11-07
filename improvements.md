# MASTER PROMPT: Complete UI/UX Overhaul of Kest — Native Desktop API Client

## YOUR ROLE

You are a **principal product designer, senior native desktop UI engineer, UX architect, and performance-focused application engineer**.

Your task is to comprehensively redesign, refine, and implement the entire UI/UX of **Kest**, our lightweight native desktop API client inspired by Bruno and Postman.

You have access to the existing application source code and the supplied screenshot. Treat the screenshot as evidence of existing problems, but **do not limit the redesign to the screenshot**.

Inspect the complete UI codebase, all existing screens, dialogs, components, interactions, navigation flows, and application states.

Your objective is to transform Kest from a functional but visually inconsistent application into an exceptionally polished, ergonomic, responsive, fast, and intuitive native developer tool.

This is an implementation task, not merely a design consultation. **Actually fix the problems in the code.**

The ultimate product should feel intentionally engineered, with the visual quality of modern professional desktop software, while preserving the simplicity and efficiency of a lightweight API client.

## 1. NON-NEGOTIABLE PRINCIPLES

Follow these principles throughout every decision:

1. **Functionality before decoration.** Make important operations easy to discover and complete.
2. **Information hierarchy before spacing.** Important information must occupy the right positions.
3. **High information density without clutter.** Developers need useful content, not oversized padding or decorative empty space.
4. **Consistency everywhere.** The same visual rules must apply to every part of the app.
5. **Native desktop ergonomics.** Design for mouse, keyboard, resizable windows, high-DPI displays, and platform conventions.
6. **Progressive disclosure.** Show necessary controls immediately; reveal secondary controls contextually.
7. **Minimalism without missing functionality.** Never remove an important feature merely to make the UI look cleaner.
8. **Performance is a feature.** Every interaction should feel immediate.
9. **No unnecessary dependencies.** Work with the existing native framework and architecture.
10. **No feature bloat.** Do not introduce authentication systems, Git integration, cloud synchronization, collaboration, or other unrelated features as part of this redesign.

Do not rewrite the application from scratch unless absolutely necessary. Preserve existing request execution, collections, environments, import/export, data handling, and other working functionality.

The challenge is to make the existing capabilities far easier and more pleasant to use.

---

# PART I — CRITICAL PROBLEMS IN THE CURRENT SCREENSHOT

## 2. Fix the global information hierarchy

The screenshot shows too many UI regions competing for attention:

- Native title bar
- Global application toolbar
- Collection header
- Request tab bar
- Breadcrumb/name row
- Request method and URL row
- Resolved URL row
- Request configuration tabs
- Response tabs and metadata
- Content panels
- Sidebar footer
- Global status footer

Each region independently consumes height, and several add little value.

### Required improvements

Establish a hierarchy of five major regions:

1. Application-level controls
2. Collection navigation
3. Open request tabs
4. Request configuration and execution
5. Response inspection

Secondary controls should remain visually subordinate.

Avoid creating a separate full-height row for every piece of contextual information.

Remove redundant wrappers, unnecessary separators, duplicate controls, and decorative toolbar regions.

The primary request editor should remain the focal point.

## 3. Fix the excessive vertical stacking

The screenshot has multiple horizontal bands before the user reaches the actual editor.

This makes the interface unnecessarily fragmented.

### Implement

- Compact global toolbar.
- Compact request tab bar.
- Lightweight request title/breadcrumb area.
- Single prominent HTTP method + URL + Send row.
- Compact request configuration tabs.
- Request content beginning immediately below those tabs.

Prefer combining related controls into the same row when this improves usability.

Do not compress everything blindly. Use spacing according to information hierarchy.

The target should be to recover meaningful workspace height without making the interface crowded.

## 4. Fix the incorrect request workspace allocation

A major issue in the screenshot is that approximately half the main workspace contains an almost empty query-parameter table while the response is restricted to the other pane.

The selected request is a POST request containing a JSON payload, yet the user cannot see that payload.

### Required behavior

- When opening a request, restore the user's previously selected request tab if one exists.
- Otherwise, intelligently choose the most relevant tab.
- For a POST, PUT, or PATCH request with a configured body, prefer opening the Body tab.
- For requests with significant query parameters and no body, prefer Params.
- When creating a new request, use a sensible method-based default.
- If a request body exists but Body is not selected, make that fact discoverable.
- Request tabs may display small, subtle indicators or counts showing configured content.
- Never use the same tab selection globally for every request unless intentionally configured.

A request containing JSON should not initially look empty simply because the application defaults to Params.

## 5. Fix the overlapping borders and dividers

The screenshot shows awkward border intersections around the request/response tab row and the content areas underneath it.

Pay particular attention to:

- The horizontal line immediately below the request tabs.
- The vertical splitter between request and response.
- The intersection of this splitter with the tab-header borders.
- Active tab backgrounds touching or overlapping borders.
- Borders that appear doubled at panel boundaries.
- Editor gutters touching panel borders.
- The junction between the sidebar, tab bar, and main content.
- The bottom edge of the request/response workspace.
- The junction between sidebar footer and global status bar.

### Strict visual requirements

- One logical boundary must be drawn exactly once.
- A vertical separator should not accidentally render over a horizontal border.
- Adjacent components must not both paint the same shared edge.
- Active-tab borders must align with their underlying content panels.
- The active tab should visually connect to its content without an extra divider cutting through it.
- Splitter handles must not cause visible 2-pixel or 3-pixel seams.
- No clipping, gaps, unwanted shadows, or inconsistent line thickness.

Use centralized ownership for shared borders rather than letting every child component independently draw all four edges.

Test the interface at 100%, 125%, 150%, and 200% display scaling, including fractional device coordinates.

Prefer crisp 1-device-pixel separators after DPI-aware snapping.

This applies throughout the entire application, not only the screenshot.

## 6. Fix inconsistent tab styling

Currently, inactive request tabs appear as plain text while the active tab has a rectangular outlined appearance.

The request configuration tabs and response tabs use another visual treatment.

This creates inconsistent component behavior.

### Redesign

Create a consistent tab system with variations appropriate to each context:

**Document/request tabs**
- Compact rectangular tabs.
- Consistent height.
- Clearly distinguish active and inactive tabs.
- Support close buttons.
- Support dirty-state indicators.
- Provide hover and keyboard-focus states.
- Use a restrained active underline or surface treatment.
- Avoid thick boxes around individual tabs.

**Content tabs**
- Compact, clear selected state.
- Consistent text padding.
- Correct baseline alignment.
- Underline or low-contrast selected background, but not an arbitrary mixture.
- Counts should appear consistently, e.g. `Headers (4)`.

Ensure tab separators, selection indicators, and panel borders never overlap.

Avoid using pill-shaped controls for every tab.

## 7. Fix tab overflow and truncated request names

Several tabs are open in the screenshot, and their names are truncated excessively.

Examples include long request titles that become unreadable.

### Implement

- A horizontally scrollable request tab strip.
- Reasonable minimum and maximum tab widths.
- Active tab visibility maintained automatically.
- Smooth wheel/trackpad horizontal scrolling.
- Middle-click to close tabs where appropriate.
- Close button visible on hover or for the active tab.
- Dirty request marker that is not obscured by the close action.
- Tooltip with complete request name and relevant method.
- A tab overflow menu listing all open requests.
- Keyboard navigation between tabs.
- Consistent method label widths without wasting space.
- Optional tab reordering if it fits the existing architecture.

The plus button for opening a request must remain discoverable.

Do not let it disappear into the overflow area or overlap tab text.

## 8. Fix the unnecessary breadcrumb container

The screenshot shows a breadcrumb path inside a large outlined box, with a separate pencil icon.

The container resembles an input but mostly acts as navigation.

### Redesign

Use a compact, unobtrusive context row.

Suggested structure:

`Collection / Folder / Request name`

Requirements:

- Breadcrumb items should look navigable, not like form fields.
- Do not outline the whole breadcrumb as a text input.
- Use subtle separators.
- Make the current request name distinguishable.
- Allow renaming via double-click, context menu, or an appropriately positioned action.
- Do not permanently reserve a large amount of width for a pencil icon.
- Truncate the middle of long paths intelligently.
- Show complete paths in tooltips.
- Do not duplicate the request name unnecessarily if the active tab already provides enough context.

If the breadcrumb does not materially improve navigation for the current workflow, simplify it rather than retaining it purely for decoration.

## 9. Fix the request URL bar

The HTTP method, URL field, Save action, and Send button are among the most important controls.

Currently, the URL field contains a small Save icon at its far end, making the action ambiguous.

### Required design

Use one cohesive request execution row:

`[POST ▼] [{{base_url}}/echo __________________] [Save] [Send →]`

Exact presentation can vary, but preserve the hierarchy.

**Method selector**
- Fixed compact width.
- Easy to scan.
- Method labels never clipped.
- Consistent method colors.
- Dropdown arrow aligned correctly.
- Full keyboard support.

**URL editor**
- Takes the majority of the horizontal space.
- Clear focus indication.
- Supports long URLs and horizontal text scrolling.
- Maintains text selection during editing.
- Correctly handles environment variables.
- Provides visible unresolved-variable/error feedback.
- Avoids heavy inset borders.
- Never overlaps trailing controls.
- Supports Enter to send where appropriate and without breaking expected editing behavior.

**Save**
- Visually distinguish saving from sending.
- Prefer a toolbar action immediately beside the URL bar or an obvious request-level action.
- Show unsaved state clearly.
- Provide Ctrl+S.
- Use tooltips for icon-only presentation.
- Do not imply that the request is saved merely because a save icon exists.

**Send**
- The primary call to action.
- Strong but restrained accent color.
- Consistent height with adjacent controls.
- Appropriate minimum width.
- Clear hover, focus, pressed, disabled, and loading states.
- Ctrl+Enter to send.
- Switch to Cancel while a request is actively executing if supported.
- Prevent accidental repeated sends unless intentionally allowed.

## 10. Fix the resolved URL display

The screenshot permanently shows:

`Resolved: http://127.0.0.1:63086/echo`

This creates another row beneath the main URL field.

The information is useful, but does not necessarily deserve permanent space.

### Improvements

- Hide or collapse it when not needed, if this does not reduce debugging usefulness.
- Show the resolved URL in a tooltip, expandable detail, or compact contextual field.
- When an environment variable cannot resolve, display the problem prominently.
- Make the resolved value easy to copy.
- Do not display stale resolved values.
- Never allow environment substitutions to silently change the visible request meaning.

The resolved URL should be accessible without occupying a permanent full-width row in every request.

## 11. Fix the request parameter editor

The screenshot displays an empty table with column headings Name and Value and another empty row repeating Name and Value as placeholders.

It also includes extra blank table space and an add-row control.

This is visually wasteful.

### Implement

- Compact, well-aligned parameter table.
- Columns for enabled state, key, value, and contextual actions.
- Avoid unexplained blank columns.
- Use proper input placeholders.
- Do not repeat headings as if they were actual data.
- When no parameters exist, show a small, useful empty state or a single clean editable row.
- Add parameter through Enter, Tab, or an explicit add action.
- Support keyboard navigation between cells.
- Allow enabling and disabling individual parameters.
- Support removal and reordering where already available.
- Keep value fields usable with long strings.
- Provide visual indication for invalid entries.
- Preserve data when switching tabs.
- Allow bulk editing through a contextual action.
- Show parameter counts when meaningful.
- Keep scrollbars inside the table/editor when necessary.

The table should feel like a specialized developer input, not a generic spreadsheet pasted into the interface.

## 12. Fix the disconnected settings and collapse icons

The current request tab row includes a gear icon and an upward chevron near the center divider.

Their function is not obvious.

### Required improvements

- Determine what each icon actually controls.
- If it is a request-editor option, group it with request-editor controls.
- If it controls layout, place it near the relevant splitter or panel toolbar.
- If it collapses a panel, give it an appropriate tooltip and directional icon.
- If the action is rarely used, move it into a contextual menu.
- If unnecessary, remove it.
- Never leave a floating icon merely because it exists in the previous implementation.

Each control must have a clear purpose, visual association, keyboard accessibility, and discoverable label.

## 13. Fix the response header

The response toolbar currently contains the selected Response tab, Headers 4, a status badge, timing, response size, Text mode, dropdown, and overflow menu.

All these are compressed into one region, with inconsistent grouping.

### Recommended organization

Use a distinct response viewing section.

On the left:
- Body
- Headers (count)
- Any already-supported relevant response views

On the right:
- HTTP status
- Request duration
- Response size
- View format selector
- Contextual response actions

Example:

`Body | Headers (4)                         200 OK · 1 ms · 283 B   Text ▼   ⋯`

The exact order should adapt to available width.

Requirements:
- Keep status prominent but not oversized.
- Distinguish successful, redirected, client-error, and server-error responses.
- Preserve accessible contrast.
- Avoid misleading green styling for every non-error condition.
- Do not confuse HTTP errors with network execution failures.
- Consistently format response size and duration.
- Handle missing timing, unknown size, and no-response states.
- Ensure all items are vertically aligned.
- Never allow metadata to overlap tabs.
- Hide less-important actions in overflow when space is limited.
- Provide tooltips explaining metrics.

Use `Headers (4)` rather than an inconsistent label like `Headers 4`.

## 14. Fix the response content viewer

The screenshot shows plain-text output that echoes a request and JSON payload.

The response viewer must be optimized for reading and inspecting real API responses.

### Implement

- Use a proper read-only editor/viewer.
- Preserve whitespace where required.
- Use a developer-appropriate monospace font.
- Keep line numbers in a separate gutter.
- Maintain consistent gutter width and padding.
- Highlight the active line subtly if helpful.
- Support text selection and copying.
- Support Ctrl+A inside the response viewer.
- Provide line wrapping controls.
- Support horizontal scrolling.
- Support searching within a response.
- Preserve scroll position when switching between response views where sensible.
- Avoid excessive empty gutters.
- Ensure the first line does not touch the top border.
- Avoid clipped text at the right and bottom edges.

**Response formatting**
- Offer Pretty, Raw, and Preview only where meaningful and supported.
- Detect JSON when the response content is actually valid JSON.
- Syntax-highlight JSON, XML, HTML, and other supported formats.
- Correctly display plain-text responses.
- Never reinterpret arbitrary text as JSON just because it contains a JSON fragment.
- Handle malformed JSON gracefully.
- Preserve the original response bytes for raw inspection.
- Support copying formatted or raw response.
- For binary responses, avoid dumping unreadable data into a normal text editor.
- Do not automatically parse enormous responses on the UI thread.

**Important:** A response to `/echo` that contains HTTP header-like text is not necessarily an incorrect response. Do not change the underlying response semantics merely to make the output look prettier.

## 15. Fix the split-pane behavior

The request and response areas currently have a rigid-looking vertical division.

This is especially problematic when one panel has little content.

### Implement

- Draggable splitters.
- Visible but subtle splitter hover affordance.
- Appropriate minimum panel widths.
- Persist user-selected split ratio.
- Support equal-width reset through double-click or a menu.
- Prevent dragging panels below usable minimum sizes.
- Avoid jitter during dragging.
- Avoid editor recreation during resizing.
- Maintain caret and scroll positions.
- Support maximizing the request or response pane.
- Offer a horizontal stacked layout for narrow window sizes.
- Use a responsive breakpoint based on actual available workspace, not only total window width.

At approximately 1280px application width, with the sidebar visible, both request and response should remain reasonably usable.

When this is impossible, intelligently switch layout or provide a one-click focus mode.

Do not leave a tiny, unusable response pane just to preserve side-by-side composition.

## 16. Fix the collection sidebar

The sidebar has several problems:

- Too many visible ellipsis menus.
- Overly repetitive rows.
- Names truncated early.
- Method labels consuming inconsistent width.
- Extra indentation.
- Nested guide lines that make the hierarchy cluttered.
- Permanently displayed low-priority controls.
- Limited usable horizontal space.

### Improvements

**Collection tree**
- Use consistent hierarchy indentation.
- Reduce unnecessary horizontal offsets.
- Keep expand/collapse icons aligned.
- Maintain stable row heights.
- Make the entire relevant row clickable.
- Clearly distinguish selected and hovered items.
- Use subtle selection highlighting.
- Keep method labels aligned.
- Do not truncate standard HTTP methods.
- For uncommon long methods such as PROPFIND, allow a more suitable label treatment or tooltip.
- Request names should receive most available width.
- Apply predictable ellipsis.
- Show full names on hover.
- Preserve expanded state across navigation.
- Provide correct keyboard tree navigation.
- Avoid accidental navigation when expanding folders.
- Use lightweight tree connector lines only when they improve comprehension.

**Contextual menus**
- Do not display a three-dot menu permanently on every row.
- Reveal context actions on row hover, keyboard focus, or selected state.
- Preserve right-click access.
- Ensure touch/keyboard users can still discover actions.
- Do not reserve excessive permanent width for hover-only actions.
- Keep menus inside the screen bounds.

**Search**
- Make collection search compact.
- Use clear placeholder text such as `Search requests`.
- Support immediate filtering.
- Highlight matches without excessively changing layout.
- Preserve useful hierarchy during filtering.
- Support clearing search easily.
- Show a clean empty-results state.

**Sidebar width**
- Make sidebar resizable.
- Persist selected width.
- Establish sensible minimum/maximum widths.
- Support collapsing sidebar.
- Prevent collection names from becoming impossible to scan.
- Do not allow the sidebar to consume most of a narrow window.

## 17. Fix the sidebar footer and Import placement

The screenshot permanently shows a footer with multiple icons and an Import control.

This occupies space that could display additional requests.

### Required improvements

- Put Import/Export in a logical collection-level menu or toolbar.
- Keep it easy to find but not permanently visually dominant.
- Group collection creation, import/export, and other collection operations.
- Avoid duplicating actions.
- Give icon-only navigation controls tooltips.
- If a bottom navigation region is genuinely needed, keep it compact and clearly separated from the collection tree.
- Remove unexplained icons.
- Do not let the footer overlap the last visible collection row.
- Ensure scrolling works correctly up to the final collection item.
- Preserve essential bottom controls only when they truly need persistent visibility.

## 18. Fix the bottom status bar

The current footer displays `Ready` and additional command shortcuts.

This consumes an entire horizontal strip, while other controls already provide the same information.

### Redesign

Treat the global status bar as optional.

If retained, it should display genuinely useful, contextual information:

- Request activity
- Relevant status messages
- Background operation progress
- Errors requiring attention
- Contextual shortcuts where appropriate

Remove generic `Ready` text if it provides no value.

Avoid duplicating Commands in both the global toolbar and footer.

A low-value status bar should not consume permanent workspace height.

---

# PART II — NEW LAYOUT ARCHITECTURE

## 19. Implement a clear application shell

The ideal layout should roughly follow this structure:

```text
┌───────────────────────────────────────────────────────────┐
│ Native Titlebar / Compact Application Toolbar             │
├──────────────┬────────────────────────────────────────────┤
│ Collections  │ Open Request Tabs                          │
│              ├────────────────────────────────────────────┤
│ Search       │ Collection / Folder / Request              │
│              │                                            │
│ Collection   │ POST ▼  URL                        Send   │
│ Tree         ├─────────────────────┬──────────────────────┤
│              │ Params Body Headers │ Body Headers         │
│ Requests     │                     │ 200 OK · 1 ms        │
│              ├─────────────────────┼──────────────────────┤
│              │                     │                      │
│              │ Request Editor      │ Response Viewer      │
│              │                     │                      │
│              │                     │                      │
│              │                     │                      │
│              │                     │                      │
├──────────────┴─────────────────────┴──────────────────────┤
│ Optional compact contextual status                        │
└───────────────────────────────────────────────────────────┘
```

This is conceptual, not a pixel-perfect instruction.

Improve it where necessary through actual implementation and testing.

### Suggested sizing guidelines

Use these as initial design tokens, not immovable constants:

| Region | Suggested size |
|---|---|
| Global app toolbar | 34–40px |
| Request tab bar | 34–38px |
| Request context/breadcrumb | 28–32px |
| URL/method execution row | 38–42px |
| Content tab headers | 32–36px |
| Sidebar | 248–280px default |
| Sidebar tree rows | 29–33px |
| General toolbar icon hit area | 28–32px |
| Main content padding | 8–12px |
| Tab horizontal padding | 10–14px |

The design should be compact, but not microscopic.

Do not apply the same padding to every component.

Editors, menus, toolbars, and navigation trees have different density requirements.

## 20. Introduce a real design system

The current interface appears to be composed of individually styled widgets.

Replace arbitrary values with centralized design tokens.

### Spacing

Use a coherent 4px-based spacing scale:

- 2px for micro-alignment
- 4px for tight component internals
- 6px for compact gaps
- 8px for common spacing
- 12px for grouped controls
- 16px for major section separation
- 20–24px only when genuinely necessary

Do not use oversized gaps just to make the interface look minimal.

### Typography

Establish consistent font roles:

- Application/UI text: approximately 13–14px
- Small secondary metadata: 12–13px
- Request names: 13px
- Code/editor text: approximately 12.5–14px, configurable
- Section headings: 13–14px with medium weight
- Tooltips: approximately 12–13px

Use native-compatible fonts with strong readability.

Use a proper monospace font for code.

Avoid:
- Random font-size changes.
- Excessively pale secondary text.
- Overuse of bold.
- Inconsistent line heights.
- Misaligned text baselines.
- Text clipped vertically in compact controls.

### Colors

Define semantic colors for:

- Primary text
- Secondary text
- Disabled text
- Main background
- Sidebar background
- Editor background
- Elevated surface
- Hover background
- Selected background
- Default border
- Focus ring
- Accent action
- HTTP method categories
- Success
- Warning
- Error

Use restrained color.

Do not make every HTTP method, badge, tab, and icon visually dominant.

Differentiate GET, POST, PUT, PATCH, DELETE, and other methods consistently.

Use accessible contrast.

Aim for at least WCAG AA contrast where appropriate, including 4.5:1 for normal text and 3:1 for meaningful control boundaries.

### Borders

Standardize:

- 1px logical separators with correct DPI rasterization.
- Consistent corner radii.
- Minimal shadows.
- No arbitrary outlines on static content.
- No doubled panel borders.
- No disconnected separator fragments.

### Icons

- Use a consistent icon family.
- Consistent optical size.
- Consistent stroke thickness.
- Align icons to the visual center, not merely their bounding boxes.
- Provide sensible spacing between icon and label.
- Do not use three-dot menus for actions that deserve explicit labels.
- Do not display unexplained controls.

### Focus/hover states

Every interactive component needs predictable states:

- Default
- Hover
- Focus
- Active/pressed
- Selected
- Disabled
- Error
- Loading, where relevant

Differentiate keyboard focus from mouse hover.

---

# PART III — COMPLETE REQUEST EDITOR REDESIGN

## 21. HTTP method selection

Implement a compact but polished HTTP method dropdown.

Requirements:

- Common HTTP methods immediately accessible.
- Existing supported custom methods preserved.
- Consistent method label styling.
- Full names shown when possible.
- Menu keyboard navigation.
- No cropped labels.
- No layout shifts when selecting another method.
- Preserve URL and request configuration when changing method unless a change is explicitly necessary.

## 22. Request URL input

The URL editor should support:

- Normal URLs.
- Variable expressions.
- Long paths.
- Query strings.
- Pasting URLs.
- Selecting complete URL segments.
- Clear errors for malformed or unresolved URLs.
- Fast text editing.
- Useful tooltip/inspection for resolved values.

Do not create a visually heavy border around the entire editor.

Make the URL the most readable text in the request toolbar.

## 23. Params tab

Implement polished query parameter editing:

- Key/value rows.
- Enabled checkbox.
- Add/remove actions.
- Efficient keyboard traversal.
- Reliable horizontal sizing.
- No duplicate placeholders.
- No unnecessary empty rows.
- Counts where meaningful.
- Synchronization with URL query parameters if this functionality already exists.
- Non-destructive handling of repeated query keys.
- Correct percent-encoding behavior.

Never silently modify a user's request while merely improving presentation.

## 24. Headers tab

Apply the same table system as Params.

Requirements:

- Enabled state.
- Header key.
- Header value.
- Add/remove.
- Case-insensitive header handling where protocol behavior requires it.
- Preserve entered values and casing for display.
- Distinguish manually configured headers from automatically generated headers.
- Avoid confusing editable request headers with read-only response headers.
- Show meaningful counts.
- Keep long values readable through editing/inspection.
- Do not expose secrets in tooltips or logs unnecessarily.

## 25. Body tab

This is one of the highest-priority areas.

Build a professional request body editor supporting existing body formats.

Depending on currently implemented capabilities:

- None
- JSON
- Text
- XML
- Form URL encoded
- Multipart/form-data
- Binary/file
- Other already-supported formats

Do not implement new body engines merely for cosmetic completeness.

### JSON/body editor

- Syntax highlighting.
- Line numbers.
- Indentation.
- Tab/Shift+Tab behavior.
- Auto-indentation.
- Matching brackets where supported.
- Undo/redo.
- Copy/paste.
- Format JSON action.
- Detect JSON syntax errors.
- Preserve invalid JSON drafts for editing.
- Fast performance.
- Correct caret behavior.
- Resize without text loss.
- Optional word wrap.
- Clear editor focus state.

Provide a compact body-type selector above the editor.

Place Format, Wrap, and other editor-specific actions nearby instead of scattering them across the request toolbar.

### Form body

- Simple key/value editor.
- File picker where supported.
- Clear distinction between text and file fields.
- No gratuitous tables or controls for empty forms.

### Binary body

- Clear selected file information.
- File name and size.
- Change/remove controls.
- Avoid rendering arbitrary binary content in a text editor.

### Unsaved body state

Changing tabs or navigating temporarily must not destroy edits.

---

# PART IV — RESPONSE INSPECTOR REDESIGN

## 26. Response empty state

Before a request has been sent, avoid displaying meaningless empty panels or a fake response.

Show a subtle placeholder such as:

`Send a request to see its response.`

Optionally show the relevant keyboard shortcut.

Do not fill the empty state with large illustrations.

## 27. Sending state

When a request starts:

- Show immediate activity feedback.
- Keep the UI responsive.
- Show a subtle loading indicator.
- Provide cancel functionality if supported.
- Prevent race conditions with rapid repeated sends.
- Preserve the previous response when useful, but clearly identify it as previous/stale.
- Do not show outdated metadata as if it belongs to the current request.

## 28. Successful response state

Display:

- HTTP status code and phrase.
- Duration.
- Response size.
- Body.
- Response headers.

Ensure all metadata belongs to the same execution.

Use real measurements, not decorative placeholders.

## 29. Error states

Differentiate:

- DNS resolution error.
- Connection refused.
- Connection reset.
- Timeout.
- TLS/certificate failure.
- Invalid URL.
- Unresolved environment variable.
- Cancelled request.
- HTTP 4xx.
- HTTP 5xx.

HTTP 4xx/5xx statuses are valid HTTP responses and should still expose response bodies and headers.

Show clear, concise errors.

Include technical details in an expandable area where useful.

Do not use modal alerts for every network error.

## 30. Large responses

The response viewer must handle large bodies efficiently.

Requirements:

- Avoid blocking the UI thread.
- Avoid repeated full-body copying.
- Avoid unnecessary string conversions.
- Lazy formatting for large data.
- Virtualized rendering or equivalent efficient text-view techniques.
- Bound syntax-highlighting work.
- Efficient line-number rendering.
- Support very long single lines.
- Handle multi-megabyte responses gracefully.
- Provide a lightweight fallback viewer when full formatting is too expensive.
- Never freeze the entire application while parsing a response.

## 31. Response utilities

Preserve or provide essential, relevant actions:

- Copy body.
- Copy selected text.
- Copy response headers.
- Save response to file.
- Search in response.
- Wrap/unwrap lines.
- Switch between supported display modes.

Place infrequent utilities in a contextual menu.

Do not permanently display a large toolbar of secondary buttons.

---

# PART V — NAVIGATION AND COLLECTION EXPERIENCE

## 32. Collection tree behavior

Inspect all tree interactions.

Ensure:

- Selection and expansion work independently.
- Double-click behavior is predictable.
- Right-click opens context menu.
- Keyboard arrows navigate correctly.
- Folder indentation remains consistent.
- Rows do not overlap.
- Selection remains visible after scrolling.
- The tree retains scroll position where appropriate.
- Large collections scroll smoothly.
- Renaming items does not unexpectedly collapse the tree.
- Deleting items correctly updates selection.
- Moving items does not produce duplicate or missing rows.
- Deep nesting remains usable.

## 33. Collection search behavior

Search should be fast and useful:

- Match request names.
- Match folder/collection names where appropriate.
- Show relevant ancestor paths.
- Avoid hiding context unnecessarily.
- Support Escape to clear/dismiss search.
- No focus loss while results update.
- No layout jump after every keystroke.
- Handle thousands of entries efficiently.

## 34. Creating requests, folders, and collections

Make creation actions easy to discover.

Users should be able to understand how to:

- Create a collection.
- Add a folder.
- Create a request.
- Rename an item.
- Delete an item.
- Import a collection.
- Export a collection.

Do not make these workflows rely on obscure icons without tooltips.

Prefer a clear primary plus button with context-appropriate actions.

## 35. Drag, drop, and reordering

Where supported:

- Clear insertion indicators.
- Correct hover targets.
- Autoscroll near boundaries.
- No accidental moves.
- Preserve hierarchical integrity.
- Avoid expensive full-tree rerenders.
- Keep mouse interaction responsive.

Do not implement complicated reordering machinery if it is outside the existing feature scope.

---

# PART VI — GLOBAL APP EXPERIENCE

## 36. Global toolbar

Audit the current toolbar.

It includes sidebar toggle, environment selection, commands, theme control, and overflow actions.

### Improve

- Group related controls.
- Keep the current environment visible.
- Make the active environment easy to switch.
- Ensure the environment dropdown doesn't overflow the screen.
- Keep command search discoverable.
- Move low-frequency settings into an application menu.
- Avoid large unused horizontal toolbar areas containing isolated icons.
- Use consistent alignment and interaction states.
- Respect native window dragging and caption controls.

Do not interfere with operating-system window buttons.

## 37. Environment selection

The current environment should be clear without dominating the UI.

Requirements:

- Obvious active environment.
- Easy dropdown selection.
- Correct state updates.
- Clear indication when variables are unresolved.
- Avoid excessive modal dialogs.
- Preserve current request state while switching.
- Never send using stale resolved variables.
- Provide useful feedback for errors.

Keep the existing environment model intact.

## 38. Command palette

If the application already includes a command palette, polish it.

Requirements:

- Fast opening and dismissal.
- Immediate keyboard focus.
- Fuzzy search where feasible.
- Arrow-key navigation.
- Enter to execute.
- Escape to dismiss.
- Useful result grouping.
- Keyboard shortcuts displayed consistently.
- No lag while typing.
- No giant window for a handful of commands.

Avoid duplicating command palette access throughout the UI.

## 39. Dialogs and popovers

Perform a complete audit of every dialog and popup.

Fix:

- Inconsistent padding.
- Misaligned labels.
- Inconsistent widths.
- Unexpected button order.
- Oversized dialogs.
- Excessive empty space.
- Missing cancellation.
- Broken Escape behavior.
- Popup clipping near window edges.
- Dropdowns drawn behind other panels.
- Incorrect keyboard focus.
- Incorrect z-order.
- Inconsistent corner radii.
- Excessive shadows.
- Confusing confirmation language.

Use consistent native-style dialogs.

Reserve destructive confirmations for actions that genuinely require them.

## 40. Import/export UX

Keep import/export straightforward.

Requirements:

- Logical entry point.
- Clear supported formats.
- Native file picker.
- Useful validation feedback.
- Progress indication for large imports where meaningful.
- No unexplained success/failure.
- Avoid freezing during parsing.
- Preserve imported request structure.
- Clear errors for unsupported or malformed files.
- Accessible export location selection.

No unrelated synchronization or Git features.

---

# PART VII — MICRO-LEVEL VISUAL POLISH

## 41. Pixel-level audit checklist

Inspect and fix all of the following across the application.

### Geometry and alignment

- Text vertically off-center in buttons.
- Icons not aligned with adjacent labels.
- Chevron arrows too close to text.
- Different left paddings for similar rows.
- Unequal padding on opposite sides of fields.
- Buttons one or two pixels taller than adjoining inputs.
- Toolbar items with inconsistent baselines.
- Tab labels positioned differently from adjacent tabs.
- Input borders that do not align.
- Scrollbar tracks crossing component boundaries.
- Gaps where borders should connect.
- Borders overlapping other borders.
- Incorrect splitter placement.
- Elements extending outside visible panel bounds.
- Text clipping by one or two pixels.
- Inconsistent row heights.
- Extra whitespace below table headers.
- Uneven spacing between method labels and request names.
- Misaligned response line-number gutters.
- Different icon stroke weights.
- Misaligned selected-row backgrounds.
- Incorrect popup attachment points.

### Typography

- Incorrect line-height.
- Inconsistent font weight.
- Excessively light placeholder text.
- Poor ellipsis behavior.
- Mixed typography roles.
- Monospace text outside code contexts unnecessarily.
- UI fonts used inside code editors.
- Inconsistent numerical formatting.
- Baseline differences between badges and labels.
- Font clipping at non-default display scaling.

### Borders and backgrounds

- Double borders.
- Missing borders.
- Unexpected overlapping divider lines.
- Harsh background changes.
- Inconsistent selected backgrounds.
- Hover surfaces extending outside clickable areas.
- Inconsistent radii.
- Heavy outlines around noninteractive text.
- Visible aliasing from fractional coordinates.
- Unwanted corner gaps.
- Disconnected header and content backgrounds.

### Component states

- Missing hover states.
- Missing disabled states.
- Missing keyboard focus.
- Pressed styles inconsistent with normal buttons.
- Selected items not distinguishable from hovered items.
- Loading indicators moving adjacent content.
- Error text without sufficient contrast.
- Tooltips appearing in incorrect locations.
- Tooltip text getting clipped.
- Overflow menus extending outside the application window.

### Density

- Large empty tables.
- Unnecessary permanent button labels.
- Excessive padding around ordinary tree rows.
- Extra rows used for tiny amounts of information.
- Unnecessary section headings.
- Repeated information.
- Excessively wide method selectors.
- Excessively tall toolbars.
- Oversized status badges.
- Duplicate menu actions.
- Decorative whitespace that reduces developer workspace.

Do not consider the UI complete until these details have been checked.

---

# PART VIII — RESPONSIVENESS AND WINDOW BEHAVIOR

## 42. Window resizing

Test at least:

- 1024 × 768
- 1280 × 800
- 1280 × 832
- 1366 × 768
- 1440 × 900
- 1920 × 1080
- 2560 × 1440

The provided screenshot is approximately 1282 × 832 and should be a key regression target.

Ensure:

- No overlapping controls.
- No cropped Send button.
- No broken toolbar.
- No invisible tabs without an overflow mechanism.
- No unusable request/response panes.
- No accidental horizontal scrolling of the entire application.
- No unexpected panel disappearance.
- No footer covering content.
- No clipped context menus.
- Sensible layout changes when width decreases.

## 43. DPI and scaling

Test 100%, 125%, 150%, and 200% scaling.

Pay attention to:

- Fractional pixel borders.
- Icon sharpness.
- Text baseline.
- Row heights.
- Popup placement.
- Cursor positions.
- Splitter thickness.
- Code editor line height.
- Scrollbar size.
- Hit targets.
- Native window chrome alignment.

No controls should become blurry or visibly misaligned because of coordinate rounding.

## 44. Resizing and restoring panels

Persist where appropriate:

- Sidebar width.
- Sidebar visibility.
- Request/response split ratio.
- Selected request.
- Open request tabs.
- Editor view preferences.
- Window size and position.

Restore saved geometry safely.

Clamp invalid saved dimensions when screen resolution changes.

Do not restore an off-screen window or collapsed-to-zero panel.

---

# PART IX — INTERACTION AND KEYBOARD UX

## 45. Essential keyboard shortcuts

Support or preserve sensible shortcuts, including:

| Action | Suggested shortcut |
|---|---|
| Send request | Ctrl+Enter |
| Save request | Ctrl+S |
| New request | Ctrl+N |
| Close tab | Ctrl+W |
| Next tab | Ctrl+Tab |
| Previous tab | Ctrl+Shift+Tab |
| Command palette | Ctrl+Shift+P |
| Search within editor/viewer | Ctrl+F |
| Undo | Ctrl+Z |
| Redo | Ctrl+Y |
| Select all | Ctrl+A |
| Dismiss dialog/menu | Escape |

Respect native platform conventions and avoid overwriting existing useful bindings.

Make shortcuts context-sensitive so text editing behaves correctly.

## 46. Keyboard navigation

Audit:

- Tab order.
- Shift+Tab.
- Arrow-key navigation.
- Enter/Space activation.
- Escape behavior.
- Dropdown keyboard interaction.
- Focus after closing a modal.
- Focus after changing requests.
- Focus after deleting a selected item.
- Focus after sending.
- Focus after opening/closing the sidebar.

The application must be usable without a mouse for normal request creation, editing, sending, and response inspection.

## 47. Pointer interactions

Provide:

- Correct cursor styles.
- Predictable hitboxes.
- No tiny icon targets.
- Hover feedback.
- Consistent double-click behavior.
- Proper context menus.
- Reliable splitter dragging.
- No accidental click-through.
- No overlapping invisible hit regions.

Avoid animations that delay interaction.

## 48. Unsaved changes and navigation

Do not allow a visual redesign to introduce data loss.

Ensure:

- Dirty state is visible.
- Switching request tabs retains edits.
- Closing dirty tabs follows a clear save/discard/cancel policy.
- Saving gives subtle confirmation.
- A failed save does not clear the dirty indicator.
- Importing collections does not discard current work.
- Changing environments does not destroy request editing state.
- App shutdown handles unsaved changes appropriately.

---

# PART X — DARK MODE, ACCESSIBILITY, AND NATIVE QUALITY

## 49. Light and dark modes

Implement a coherent theme system.

Do not simply invert colors.

Both themes need:

- Consistent surface hierarchy.
- Readable editor text.
- Correct HTTP method colors.
- Accessible status badges.
- Appropriate borders.
- Subtle selections.
- Consistent hover behavior.
- Syntax highlighting designed for the background.
- Clear focus rings.
- Consistent scrollbar appearance where controllable.

Theme changes should not require reloading the entire application.

Keep transitions immediate and avoid flashing incorrect backgrounds.

## 50. Accessibility

Provide:

- Accessible names for icon buttons.
- Sufficient contrast.
- Visible focus state.
- Predictable keyboard navigation.
- Logical screen-reader semantics where supported by the native framework.
- Appropriate minimum hit targets.
- Reduced-motion compatibility.
- Scalable fonts where supported.
- Tooltips for ambiguous actions.
- State not communicated through color alone.

Avoid tiny gray text that becomes unreadable on average monitors.

## 51. Native application feel

The app must feel native, not like a web page crammed into a desktop window.

Respect:

- Operating-system title bar conventions.
- Native window resizing.
- Native file pickers.
- Native keyboard behavior.
- High-DPI rendering.
- Text selection conventions.
- Clipboard operations.
- Focus and window activation.
- Window snapping/maximizing.
- System theme preferences where supported.

Use the existing native UI framework effectively.

Do not introduce a heavy embedded web frontend just to accomplish visual styling.

---

# PART XI — PERFORMANCE AND MEMORY EFFICIENCY

## 52. Performance constraints

The redesign must not significantly increase memory usage, startup time, or interaction latency.

Focus on:

- Lightweight reusable widgets.
- Minimal unnecessary allocations.
- Avoiding full-tree updates for minor state changes.
- Incremental rendering.
- Efficient clipping.
- Virtualized long lists.
- Avoiding expensive layout recalculation.
- Efficient text rendering.
- Lazy syntax highlighting.
- No duplicated response buffers unless required.
- No excessive animation systems.
- No unnecessary runtime dependencies.

## 53. Editor performance

The request and response editors should:

- Remain responsive with large text.
- Avoid rerendering all visible content after each keystroke.
- Preserve caret and selection during resize.
- Avoid unnecessary parsing on every character.
- Support responsive scrolling.
- Handle long unbroken lines efficiently.
- Avoid expensive syntax highlighting outside the visible region where feasible.

## 54. Collection performance

The sidebar should remain smooth with:

- Hundreds of folders.
- Thousands of requests.
- Long request names.
- Deeply nested collections.
- Active search filtering.
- Rapid expansion/collapse.
- Rapid selection changes.

Use virtualization or equivalent optimized rendering when useful.

## 55. Measure performance

Establish before/after measurements where feasible.

Track:

- Cold startup time.
- Idle memory.
- Memory with several open requests.
- Time to switch requests.
- Typing responsiveness.
- Sidebar scrolling responsiveness.
- Time to display medium and large responses.
- Frame responsiveness during pane resizing.

Do not claim performance improvement without measurement.

A UI redesign that looks better but makes the native app noticeably slower is unacceptable.

---

# PART XII — APP-WIDE AUDIT BEYOND THE SCREENSHOT

## 56. Inspect every existing screen and UI state

Do not stop after fixing the main request editor.

Search the entire UI codebase for:

- Toolbars
- Tab controls
- Tree views
- Scroll containers
- Split panes
- Dialogs
- Dropdowns
- Popup menus
- Context menus
- Text inputs
- Code editors
- Tables
- Empty states
- Error views
- Loading views
- Environment controls
- Collection management views
- Import/export views
- Settings/preferences
- Notifications
- Status indicators

For every existing screen or component, inspect:

1. Layout correctness.
2. Visual hierarchy.
3. Spacing.
4. Alignment.
5. Borders.
6. Typography.
7. Control placement.
8. Responsiveness.
9. Keyboard behavior.
10. Loading and error behavior.
11. Performance.
12. Consistency with the design system.

If another screen has similar defects, correct them rather than leaving them untouched.

Do not invent additional screens merely to satisfy this checklist.

## 57. Identify and remove redundant UI

Look for:

- Duplicate buttons.
- Duplicate shortcut descriptions.
- Repeated breadcrumbs.
- Unnecessary headers.
- Permanent menus with little value.
- Placeholder labels that don't help.
- Unused toolbar space.
- Decorative separators.
- Multiple controls for the same action.

Before removing anything, verify whether it serves a real workflow.

Move secondary actions rather than deleting functionality.

## 58. Fix all clipping and overflow

Review:

- Long collection names.
- Long request names.
- Long URLs.
- Long method names.
- Long environment names.
- Long header keys and values.
- Long response lines.
- Small application windows.
- High-DPI scaling.
- Empty and populated tables.
- Large context menus.
- Tooltips near window corners.

Every overflow state must be intentional.

Never let text render underneath an icon, another panel, or a separator.

---

# PART XIII — REQUIRED IMPLEMENTATION STRATEGY

## 59. Phase 1: Audit the existing code

First inspect the application architecture.

Identify:

- UI entry points.
- Shared component implementations.
- Current styling mechanism.
- Layout constraints.
- Event handling.
- State management.
- Rendering pipeline.
- Editor implementation.
- Collection tree implementation.
- Theme handling.
- Relevant performance bottlenecks.

Create an internal map of the UI before making changes.

Determine which defects originate from shared components and fix them centrally.

Avoid patching every screen with unrelated magic numbers.

## 60. Phase 2: Create design tokens and reusable primitives

Implement or standardize:

- Spacing tokens.
- Typography roles.
- Color tokens.
- Border tokens.
- Icon sizes.
- Buttons.
- Dropdowns.
- Tabs.
- Splitters.
- Tree rows.
- Input fields.
- Context menus.
- Status badges.
- Editor toolbars.
- Dialog layouts.

Keep this lightweight.

Do not create a huge abstraction layer for a small application.

## 61. Phase 3: Fix application-level geometry

Fix:

- Global header.
- Sidebar.
- Request tab strip.
- Main panel geometry.
- Splitters.
- Footer.
- Window resizing.
- Border intersections.

Do this before applying decorative polish.

A visually attractive UI with incorrect geometry is still broken.

## 62. Phase 4: Improve important workflows

Prioritize:

1. Opening a request.
2. Editing method and URL.
3. Editing query parameters.
4. Editing headers.
5. Editing request body.
6. Sending a request.
7. Inspecting response body.
8. Inspecting response headers.
9. Switching requests.
10. Switching environments.
11. Saving changes.
12. Importing/exporting collections.

Optimize the number of clicks, context switches, and unnecessary pointer movements.

## 63. Phase 5: Fix secondary screens

Apply the same component and layout standards to every existing dialog, popup, secondary window, and settings view.

Do not create inconsistent islands of old UI.

## 64. Phase 6: Visual regression and edge-case testing

Test the main view with:

- Empty GET request.
- GET request with several query parameters.
- POST request with JSON body.
- POST multipart form.
- File upload request.
- Request with many headers.
- Long URL.
- Long request name.
- Deep collection nesting.
- Empty collection.
- Large collection.
- Successful JSON response.
- Plain-text response.
- Error response.
- No response/network failure.
- Slow in-progress request.
- Large response.
- Narrow window.
- Maximized window.
- Light mode.
- Dark mode.
- High-DPI scaling.

Use screenshots or visual regression tooling where available.

Compare the result against the original screenshot and specifically verify the original border-overlap problems are gone.

## 65. Phase 7: Polish every visible imperfection

Perform a deliberate final pass looking only for small defects.

Examples:

- 1px offsets.
- Wrong icon alignment.
- Unwanted shadows.
- Odd separator intersections.
- Inconsistent tooltip spacing.
- Incorrect selected tab baseline.
- Tiny gaps between panels.
- Border color mismatches.
- Truncated text where more room is available.
- Unnecessary empty rows.
- Different button heights.
- Inconsistent focus-ring thickness.
- Misaligned dropdown arrows.
- Hover backgrounds not covering the complete row.

Do not dismiss these as insignificant.

They strongly affect perceived product quality.

---

# PART XIV — ACCEPTANCE CRITERIA

The redesign is not complete until the following conditions are satisfied.

### Layout

- No visible overlapping borders.
- No doubled shared dividers.
- No clipped important controls.
- No accidental panel gaps.
- Proper alignment throughout.
- Responsive panes.
- Sidebar resize works.
- Request/response splitter works.
- Tab overflow works.
- Main editor maximizes useful space.

### Usability

- Core request editing controls are immediately discoverable.
- A POST request with a body makes that body easy to find.
- Empty sections do not unnecessarily dominate the layout.
- Important actions remain visible.
- Secondary controls do not overwhelm the main workflow.
- Contextual menus are logically positioned.
- The app remains efficient with many open requests.
- Full request names are discoverable.
- Keyboard operations work correctly.

### Visual quality

- Consistent typography.
- Consistent colors.
- Consistent spacing.
- Consistent active states.
- Consistent button sizes.
- Consistent icon sizes and alignment.
- Accessible contrast.
- Well-designed dark and light modes.
- Professional native-desktop appearance.
- No obviously unfinished visual components.

### Reliability

- Existing request execution continues working.
- Request bodies remain intact.
- Headers and parameters remain intact.
- Collections remain intact.
- Environment variables resolve correctly.
- Import/export continues working.
- Saving remains reliable.
- No introduced data-loss problems.
- Correct handling of request errors and cancellation.

### Performance

- No significant idle memory regression.
- No noticeable UI responsiveness regression.
- Efficient sidebar navigation.
- Responsive editor typing.
- Responsive splitter dragging.
- Large responses do not freeze the app.
- No unnecessary heavy frameworks or dependencies.

### Quality verification

- Test the same approximate 1282 × 832 dimensions as the supplied screenshot.
- Test at least one smaller and one larger window.
- Test both themes.
- Test high-DPI rendering.
- Test keyboard-only navigation.
- Test different request methods and body types.
- Verify every visible control works.
- Confirm that the previously observed border intersections are fixed.

---

# PART XV — DELIVERABLES AND WORKING RULES

## 66. Required deliverables

You must provide:

**1. Actual code changes**

Implement the redesigned UI in the existing application.

**2. Audit summary**

Describe the major UI problems discovered in the screenshot and throughout the codebase.

**3. Fix summary**

Explain the changes made to the layout, navigation, request editor, response inspector, shared components, and secondary screens.

**4. Before/after evidence**

Where possible, provide screenshots of the redesigned app at the original window size, including light and dark mode.

**5. Verification results**

State which interactions, screen sizes, and important request flows were tested.

**6. Remaining limitations**

Clearly identify anything that could not be completed or verified. Do not falsely report unimplemented improvements as finished.

## 67. Rules while coding

- Do not respond with only a list of suggestions.
- Do not stop after a cosmetic color and padding update.
- Do not simply make everything smaller.
- Do not remove important controls without providing a sensible alternative.
- Do not change request/network semantics for UI convenience.
- Do not introduce feature bloat.
- Do not sacrifice native performance.
- Do not blindly copy Postman, Bruno, VS Code, or another application.
- Do not rewrite reliable working logic unnecessarily.
- Do not scatter arbitrary layout constants throughout the codebase.
- Do not ignore secondary dialogs and menus.
- Do not claim completion without running the app and verifying the result where tooling allows.

When a design decision has alternatives, choose the option that provides the clearest workflow with the least visual and technical complexity.

Prioritize real implementation over elaborate planning documents.

---

# FINAL PRODUCT VISION

Kest should be a **beautifully engineered, lightweight, native API client**.

It should combine:

- The clarity and simplicity of Bruno.
- The practical request/response capabilities users expect from Postman-like tools.
- The keyboard ergonomics and information density of professional developer software.
- The responsiveness and low overhead of a carefully optimized native application.
- A consistent, refined visual system that feels purpose-built.

When opening Kest, a developer should immediately understand:

- Where their requests are.
- Which request is active.
- How to edit its URL, parameters, headers, and body.
- How to send it.
- Where the response appears.
- Whether the request succeeded.
- How to inspect, copy, and save the result.

There should be no wasted visual complexity, no meaningless permanent sections, no clipped important content, no awkward border intersections, and no confusing layout decisions.

**The application should feel effortless to use, not merely pleasant to look at.**

Treat every unnecessary click, every wasted pixel, every inconsistent border, every confusing icon, every layout jump, and every avoidable delay as an opportunity for improvement.

Do a complete professional UI/UX overhaul of the existing implementation.

**The final result must be substantially more polished, usable, consistent, and efficient than the current screenshot—without becoming bloated or sacrificing native performance.**