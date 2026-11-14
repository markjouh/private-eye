# Private Eye: accessibility conformance report

Assessed 14 November 2026, against the code in this checkout. Scope: the iOS app (target `Eyes`): the
camera screen, the Memories sheet, and the Siri / Action button shortcuts.

Two standards:

- **WCAG 2.2, Level A and AA**, read for native software the way W3C's WCAG2ICT note reads it.
- **Apple's Accessibility Nutrition Labels** (the nine App Store labels and Apple's evaluation
  criteria for each).

## How this was assessed, and what the verdicts mean

| Evidence | What it covers |
|---|---|
| Code reading | Everything. |
| iOS simulator (iPhone 17, iOS 27.2), the real `Eyes/UI` files over a stub model | The accessibility tree the app hands to assistive technology (labels, values, hints, traits, custom actions, order), read in-process, with activation, the custom action and Magic Tap invoked the way VoiceOver invokes them. Real touches on every part of the screen, and the forget-and-confirm flow in Memories. Screenshots at the default text size, AX2, AX3 and AX5. The harness was a throwaway and is not in the repository. |
| Calculation | Contrast ratios, with the WCAG formula, including the worst case for text over camera video. |
| **Not done** | Nothing was run on a phone. VoiceOver, Voice Control, Switch Control, Full Keyboard Access and braille were not exercised: the simulator has none of them. `Speaker`'s VoiceOver path cannot run in the simulator at all. |

Verdicts:

- **Pass**: the code demonstrably does it, shown by reading, the simulator checks or calculation.
- **Fail**: it does not, today.
- **Not applicable**: the criterion has nothing to apply to in this app.
- **Needs device check**: written to pass, but passing depends on how an assistive technology
  behaves at run time, which nobody has observed yet. Not a pass until the test script at the end has
  been run on a phone.

## How the app is operated

The whole screen is one press surface (`Eyes/UI/PressSurface.swift`): tap for a description, hold
and speak to ask. That surface is no longer an accessibility element. It used to be a full-screen
direct-touch area, which leaves VoiceOver unable to reach anything else, and its only name was a
sentence of instructions that no Voice Control user would say. Assistive technology now acts on the
picture of the button (`talkButton` in `Eyes/UI/ContentView.swift`).

| | Describe what is ahead | Ask a question | Hear / read the reply |
|---|---|---|---|
| Touch | Tap anywhere | Hold anywhere, speak, release | App's own voice, and captions |
| Camera Control, volume buttons | Click | Hold, speak, release | same |
| Siri, Action button, Shortcuts | "Describe What's Ahead" | "Ask a Question", run again to stop | same |
| VoiceOver | Double-tap ("Describe, button") | Double-tap and hold while speaking; or Magic Tap to start and again to stop; or the "Ask a question" action, then double-tap "Listening" | Spoken by VoiceOver itself (one voice, the user's voice and rate), shown on a braille display, and readable as "You asked" / "Answer" elements |
| Voice Control | "Tap Describe" | "Show actions for Describe", "Ask a question". Stopping by voice is the open problem, see gap 5 | App's own voice, and captions |
| Switch Control, Full Keyboard Access | Select / Space on Describe | "Ask a question" in the actions menu, then select "Listening" | same |

Haptics: the tap felt when a press begins comes with the button turning to "Listening…". For someone
who cannot see that, it is the only confirmation that a held press registered; listening started by
a toggle also plays the system's recording tone. The obstacle haptics (off until asked for) carry a
distance that is also in the status line and in the spoken descriptions.

## WCAG 2.2, Level A and AA

All 55 criteria (31 A, 24 AA; 4.1.1 Parsing was removed in 2.2). File names are under `Eyes/`.

| # | Criterion | Level | Verdict | Evidence or reason |
|---|---|---|---|---|
| 1.1.1 | Non-text Content | A | **Fail** (one line outside the UI) | Camera picture and overlays are one image element, "Camera view", whose value names the people and the user's own things in view (`UI/ContentView.swift` `cameraView`); the full description is what a tap speaks, and it is also shown as text. Memories icon button is labelled; decorative thumbnails are hidden. Every spoken reply is also text, except "Something went wrong.", which `AppModel.answerWithModel` speaks without putting it in `answer`. Gap 4. |
| 1.2.1 | Audio-only and Video-only (Prerecorded) | A | Not applicable | No prerecorded media. |
| 1.2.2 | Captions (Prerecorded) | A | Not applicable | No prerecorded media. |
| 1.2.3 | Audio Description or Media Alternative (Prerecorded) | A | Not applicable | No prerecorded media. |
| 1.2.4 | Captions (Live) | AA | Not applicable | No live synchronized media. (The app's own speech is captioned anyway.) |
| 1.2.5 | Audio Description (Prerecorded) | AA | Not applicable | No prerecorded video. |
| 1.3.1 | Info and Relationships | A | Pass | Question and answer are told apart in words ("You asked:", "Answer:"), not only by size and color (`ContentView` `captionText`, `UI/MemoryView.swift` Recent rows). Button has the button trait and is "not enabled" while loading; Memories sections are headers. All seen in the simulator tree. |
| 1.3.2 | Meaningful Sequence | A | Pass | Order is set explicitly with sort priorities: Describe, question, answer, Memories, Camera view, Status. The simulator tree comes out in that order. |
| 1.3.3 | Sensory Characteristics | A | Pass | Instructions name actions ("Tap anywhere · hold to ask"), not shapes, colors or positions. |
| 1.3.4 | Orientation | AA | **Fail** | Locked to portrait (`project.yml`, `UISupportedInterfaceOrientations`). Not "essential" in WCAG's sense: it is a limit of the camera pipeline, not of the task. Gap 1. |
| 1.3.5 | Identify Input Purpose | AA | Not applicable | No fields that collect information about the user. |
| 1.4.1 | Use of Color | A | Pass | Each button state has its own icon and title as well as its color; object tags carry text; a tentative match is a "?" and a dashed outline. |
| 1.4.2 | Audio Control | A | Pass | Nothing plays by itself: speech only answers a press, and any new press stops it. |
| 1.4.3 | Contrast (Minimum) | AA | Pass | Calculated, see "Contrast" below. Lowest text ratio is 4.59:1. Three things were below 4.5:1 and were changed: button fills, black tag text on blue and violet tags, the swipe "Forget" button. |
| 1.4.4 | Resize Text | AA | Pass | All text follows Dynamic Type. Captions grow to the system maximum (254% at AX5). Status line, object tags and the button stop at about 200% (217%, 208%, 215%). Nothing is truncated; a reply too long for the screen scrolls. Seen in simulator screenshots at AX2, AX3 and AX5. |
| 1.4.5 | Images of Text | AA | Pass | No images of text. Tags are drawn text that scales (`UI/DetectionOverlay.swift`, `FaceOverlay.swift`, `BelongingOverlay.swift`). |
| 1.4.10 | Reflow | AA | Pass | One column; only vertical scrolling (captions, Memories list), at every text size tried. |
| 1.4.11 | Non-text Contrast | AA | Pass | Button icon and state are white on fills of 5.3:1 or more; the Memories glyph is at least 8.5:1. Object outlines and shading over live video cannot promise 3:1, but nothing depends on them: each object's tag says what it is, on its own solid background. |
| 1.4.12 | Text Spacing | AA | Not applicable | WCAG2ICT: applies only to markup-based content whose spacing a user can override. |
| 1.4.13 | Content on Hover or Focus | AA | Not applicable | Nothing appears on hover or focus. |
| 2.1.1 | Keyboard | A | Needs device check | The platform's keyboard interface is Full Keyboard Access, which drives the same elements: Describe, its "Ask a question" action (no hold, so no timing), Memories, the list. Not tried with a keyboard. |
| 2.1.2 | No Keyboard Trap | A | Needs device check | Standard focus; the sheet has Done and the system Escape. Not tried. |
| 2.1.4 | Character Key Shortcuts | A | Not applicable | No single-character shortcuts. |
| 2.2.1 | Timing Adjustable | A | Pass | No time limits. Listening lasts as long as the button is held or until it is toggled off; captions stay until the next press; the screen never sleeps. The 0.35 s that separates a tap from a hold costs nothing: a slow tap with nothing said also gets the description. |
| 2.2.2 | Pause, Stop, Hide | A | Pass | The only content that keeps moving is the live camera view with its tags and readouts, which is the activity itself (essential). This is a judgement: the "detector ms" figure in the status line updates with it. |
| 2.3.1 | Three Flashes or Below Threshold | A | Needs device check | Nothing flashes by design. Object shading appears and disappears with the detector (up to 10 times a second), and whether a large unstable detection flickers past the threshold cannot be told from code. Gap 8. |
| 2.4.1 | Bypass Blocks | A | Not applicable | WCAG2ICT: applies to sets of software programs. |
| 2.4.2 | Page Titled | A | Pass | The app has its name; the Memories screen has a navigation title. |
| 2.4.3 | Focus Order | A | Needs device check | Element order is verified (1.3.2). Where VoiceOver's focus goes when the Memories sheet opens and closes is left to the system and was not observed. |
| 2.4.4 | Link Purpose (In Context) | A | Not applicable | No links. |
| 2.4.5 | Multiple Ways | AA | Not applicable | WCAG2ICT: applies to sets of software programs. |
| 2.4.6 | Headings and Labels | AA | Pass | "Describe", "Memories", "Forget", "Done"; sections "People", "Things", "Recent". |
| 2.4.7 | Focus Visible | AA | Needs device check | Focus indicators are drawn by the system (VoiceOver cursor, keyboard focus ring, Switch Control cursor) around elements whose frames match what is on screen. Not observed. |
| 2.4.11 | Focus Not Obscured (Minimum) | AA | Pass | Nothing is laid over the controls; the Memories sheet is modal. |
| 2.5.1 | Pointer Gestures | A | Pass | Tap and hold only. Swipe-to-forget in Memories also has a long-press menu (`MemoryView.swift` `forgettable`). |
| 2.5.2 | Pointer Cancellation | A | **Fail** | Listening starts on touch-down. That part is essential: push-to-talk cannot start on release, and the frame of that moment is the subject. But the function completes on release, and there is no way to abort: the button fills the screen, so a finger cannot slide off it, and a touch the system cancels counts as a release. Gap 2. |
| 2.5.3 | Label in Name | A | Pass | The accessible name is the visible title ("Describe", "Listening", "Thinking", "Loading"), checked in the simulator tree. |
| 2.5.4 | Motion Actuation | A | Not applicable | Nothing is triggered by moving the phone. |
| 2.5.7 | Dragging Movements | AA | Pass | Nothing requires a drag: forgetting has a menu, the sheet has Done. |
| 2.5.8 | Target Size (Minimum) | AA | Pass | The main target is the screen. Memories is 52 by 52 pt at the default size (measured in the simulator); list rows are 52 pt or taller. |
| 3.1.1 | Language of Page | A | Pass | The app's only localization is English (`developmentRegion = en`), and the app's own voice is `en-US` (`Speech/Speaker.swift`). |
| 3.1.2 | Language of Parts | AA | Not applicable | Everything is English. |
| 3.2.1 | On Focus | A | Pass | Moving focus does nothing. |
| 3.2.2 | On Input | A | Pass | No setting changes context. "Show memories" opens the sheet because it was asked to. |
| 3.2.3 | Consistent Navigation | AA | Not applicable | WCAG2ICT: applies to sets of software programs. |
| 3.2.4 | Consistent Identification | AA | Not applicable | WCAG2ICT: applies to sets of software programs. (Within the app, "Forget" and "Ask a question" are named the same everywhere.) |
| 3.2.6 | Consistent Help | A | Not applicable | No help mechanism. |
| 3.3.1 | Error Identification | A | Not applicable | No input is validated. (A model that fails to load says so on the button and in an announcement.) |
| 3.3.2 | Labels or Instructions | A | Pass | "Tap anywhere · hold to ask" on the button; a hint for VoiceOver; examples in the empty Memories sections. |
| 3.3.3 | Error Suggestion | AA | Not applicable | No detected input errors. |
| 3.3.4 | Error Prevention (Legal, Financial, Data) | AA | **Fail** | Remembered faces and things are the user's stored data. The Memories screen now confirms every deletion (`MemoryView.swift`). The voice commands "Forget Sarah" and "Forget everything" delete at once, with no confirmation and no undo. Gap 3. |
| 3.3.7 | Redundant Entry | A | Not applicable | Nothing is entered twice. |
| 3.3.8 | Accessible Authentication (Minimum) | AA | Not applicable | No sign-in. |
| 4.1.2 | Name, Role, Value | A | Pass | Simulator tree: "Describe" is a button that starts a media session, with the action "Ask a question"; while loading it is "Loading", not enabled; "Camera view" is an image with a value; "Status" has a value; Memories rows carry a "Forget" action. Activating each did the right thing. |
| 4.1.3 | Status Messages | AA | Needs device check | Posted as announcements, without moving focus: "Ready", "Model failed to load", "Thinking" when an answer takes more than 1.5 s (`ContentView.swift`), and every reply (`Speaker.swift`). "Listening" is deliberately not spoken: the microphone is open. Announcements only exist with VoiceOver running, so none of this has been heard. |

Totals: 24 pass, 4 fail, 6 need a device check, 21 not applicable.

### Contrast

Text over the camera picture sits on translucent black. The worst case is a white picture behind it.

| Text | On | Ratio (worst case) |
|---|---|---|
| Status line, white | black at 55% over video | 4.76:1 |
| Question, white at 75% | black at 65% over video | 4.78:1 |
| Answer, white | black at 65% over video | 6.98:1 |
| Memories glyph, white | black at 70% over video | 8.52:1 |
| Button title, white | blue / red / amber / grey fills | 5.77 / 5.77 / 5.32 / 6.45:1 (the system blue, red, orange and grey gave 3.65 / 3.41 / 2.06 / 3.26:1) |
| Object tag, black or white chosen by the tag's luminance | generated tag color | at least 4.59:1 on every hue (black alone fell to 3.39:1 on hues 229° to 267°) |
| Face tag, black | white | 21:1 |
| Belonging tag, black | yellow | 14.9:1 |
| Memories sheet: primary / secondary / red / blue | dark list row | 17.0 / 5.95 / 4.99 / 4.66:1 |
| Swipe "Forget", white | dark red | 5.77:1 (system red: 3.41:1) |

With Increase Contrast or Reduce Transparency on, the backings become solid black and the question
turns full white. The Memories figures hold for the dark appearance, which the app forces
(`EyesApp.swift`); the sheet was dark in the simulator. In the light appearance the system's secondary
text and red would be 3.44:1 and 3.55:1, so see gap 11.

## Apple Accessibility Nutrition Labels

Apple's rule for every label: a user must be able to complete all the app's common tasks with that
feature. Common tasks here: first launch (permission prompts, model loading), describe, ask, hear or
read the reply, open Memories, forget a person or thing.

| Label | Can it be claimed? | Against Apple's criteria |
|---|---|---|
| VoiceOver | **Not yet: device check first.** No known blocker in code. | Every element reachable, labelled, with type and state; the long-press (hold to ask) is also a custom action and Magic Tap; activation equals a tap; replies and status changes are announced; the sheet is modal with an escape. All of it rests on VoiceOver behaviour nobody has observed: test script A. |
| Voice Control | **Cannot claim yet.** | Names match the visible titles and "Tap Describe", "Tap Memories", "Tap Done", "Scroll down" have targets. Apple requires that recording can be started and stopped by voice alone. It can be started; the words that stop it ("Tap Listening") are heard by the app too and end up in the question. Gap 5. |
| Larger Text | **Can claim.** | Text enlarges to 200% or more everywhere and to the system maximum for the reply; no overlap or truncation; side-by-side rows stack; long text scrolls by dragging. Seen in the simulator at four sizes. Confirm on the phone (script D). |
| Dark Interface | **Can claim.** | Dark by default for every common task, whatever the system setting. One wrinkle: the generated launch screen follows the system appearance, so in Light Mode it flashes white before the app draws. Gap 11 removes it. |
| Differentiate Without Color Alone | **Can claim.** | No state or meaning is carried by color alone (see 1.4.1). |
| Sufficient Contrast | **Can claim.** | 4.5:1 or better for text and 3:1 or better for control states by default, calculated above, in the dark appearance the app always uses. Worth one pass with Accessibility Inspector on the phone. |
| Reduced Motion | **Can claim.** | The app's one animation, the button shrinking when pressed, is switched off by Reduce Motion (`ContentView.swift`). No parallax, zoom, spin or auto-advancing content. The sheet uses the system transition. |
| Captions | **Not yet: one line.** | Apple accepts a text transcript of spoken audio. Everything the app says is on screen as it is said, and kept under Recent in Memories, except "Something went wrong." (gap 4). Whether to tick a label designed for video is a judgement call; the criteria are met once that line is in. |
| Audio Descriptions | **Do not claim.** | Not applicable: the app plays no video. Describing the camera view is its function, not an audio-description track. |

## Known gaps

1. **Portrait only (WCAG 1.3.4).** Someone with the phone mounted sideways gets a sideways interface
   and a sideways picture. Supporting landscape takes: the landscape orientations in `project.yml`;
   in `Vision/CameraController.swift`, an `AVCaptureDevice.RotationCoordinator` setting the video and
   depth connections' rotation instead of the fixed 90°, and the same for the preview in
   `UI/CameraPreview.swift`; a decision for the detector, whose input is exported as 3:4 portrait
   (letterbox landscape frames or export a second shape); and a landscape layout, because captions,
   status and button do not fit a 402 pt high screen stacked. "Left" and "right" come from the
   upright frame and would stay correct.
2. **No way to abort a press (WCAG 2.5.2).** Needs `AppModel.abortTurn()` (stop the recognizer and
   the model, no reply). Then: a press released far from where it started, a touch the system
   cancels, and a cancelled hardware-button press abort instead of answering; VoiceOver's two-finger
   scrub can do the same. About 15 lines in `PressSurface.swift`, `HardwareTrigger.swift` and
   `ContentView.swift` once the method exists.
3. **Voice commands delete without confirmation (WCAG 3.3.4).** `Memory/Commands.swift` already drops
   a command when the speaker has second thoughts in the same breath. What is missing is a check
   after it: "Forget Sarah?" and a spoken yes before `store.forget`, or a spoken "undo" that restores
   the last thing forgotten.
4. **One spoken message has no text (WCAG 1.1.1, Captions label).** In `AppModel.answerWithModel`'s
   `catch`, set `answer = "Something went wrong."` before speaking it.
5. **Voice Control cannot stop a question cleanly (Voice Control label).** Listening that was started
   by a toggle rather than a held button should end by itself when the speaker pauses. That belongs
   in `AppModel`, where the Siri and Action button toggle would get it too. The pause length is a
   time limit of its own (WCAG 2.2.1), so it should be generous, and holding the button remains the
   way to take as long as needed.
6. **Without VoiceOver, state is not spoken.** A blind user who is not running VoiceOver hears nothing
   when the model finishes loading or fails to load, and presses during loading do nothing, silently.
   The announcements in `ContentView` only reach assistive technology. `AppModel` could say "Ready."
   and "The model failed to load." through `Speaker` when VoiceOver is off. Related: if camera access
   is refused, `CameraController.start` returns silently and every press ends in "Something went
   wrong."; it should say what is wrong.
7. **VoiceOver talking into the microphone (needs device check).** The button is marked as starting a
   media session so VoiceOver keeps quiet when it is activated, and nothing is announced on entering
   `listening`. One case is left: starting a question while VoiceOver is still reading a reply.
   `Speaker` hands VoiceOver one sentence at a time so at most one is left to finish, but it cannot
   take that sentence back. If it shows up in transcripts, the fix is echo cancellation on the audio
   session (voice-processing input) or a short wait before the recognizer starts.
8. **Flicker (WCAG 2.3.1, needs device check).** If shading on a large object visibly flashes more
   than three times a second, the detector needs hysteresis (keep a detection for a few frames after
   it drops below the display threshold), in `Vision/ObjectDetector.swift`.
9. **Volume buttons are taken over.** While the app is in front, both volume buttons are press-to-talk
   (`UI/HardwareTrigger.swift`); the system offers no way to take only the Camera Control. Volume has
   to be changed in Control Centre or by asking Siri. Not a WCAG failure, but hard-of-hearing users
   and VoiceOver users (who adjust speech volume with those buttons) will notice. Spoken "louder" and
   "quieter" commands would help.
10. **The diagnostic status line crowds the captions at the largest text sizes.** At AX5 with model
    statistics showing, it takes about a third of the screen and the reply gets three or four lines
    at a time (it scrolls). Dropping the developer figures from release builds would give the room
    back.
11. **Light Mode edges (Dark Interface, Sufficient Contrast).** Add
    `INFOPLIST_KEY_UIUserInterfaceStyle: Dark` to `project.yml` so the launch screen and every system
    sheet are dark regardless of the system setting.
12. **Hold-to-ask does not start inside overflowing captions.** When a reply is too long to fit, the
    caption box scrolls on a drag and describes on a tap; a hold has to start anywhere else. Only
    happens at large text sizes with long replies.
13. **English only.** Not a conformance failure. On a phone set to another language, check which voice
    VoiceOver uses for the English replies.

## Manual test script

On an iPhone 17 Pro with the app installed. Settings are under Settings > Accessibility unless
stated. Teach the app one person and one thing first, so Memories is not empty.

**A. VoiceOver** (VoiceOver > on)

1. Launch (on a fresh install, the camera, microphone and speech prompts are read and can be
   answered). Expect the app's name, focus on "Loading, dimmed, button", then "Ready" when the model
   has loaded.
2. Focus "Describe, button" and wait for the hint. Double-tap. Expect: VoiceOver says nothing about
   the button; the description is spoken once, in the VoiceOver voice at the VoiceOver rate, with no
   second voice; a reply of three or more sentences is read to the end.
   If nothing is spoken, remove `.startsMediaSession` from `talkButton`. If only the first sentence
   is spoken, `Speaker.announcementDidFinish` is not being called.
3. Double-tap again while it is still speaking. Expect the old reply to stop within a sentence and
   the new one to start.
4. Double-tap and hold on Describe until the tones, ask "What colour is the cup?", lift. Expect the
   question on screen with only your words in it, then the answer.
5. Magic Tap (two-finger double-tap) with focus on Status. Expect the recording tone and a button
   that now reads "Listening". Ask a question; Magic Tap again. Expect the answer, and only your
   words in the question.
6. Focus Describe, swipe down to "Ask a question", double-tap. Ask; double-tap "Listening". Same
   expectations.
7. Start step 4 while a long reply is being read. Expect VoiceOver to fall silent; check the
   question for words from the old reply (gap 7).
8. Swipe right from Describe. Expect, in order: "You asked: …", "Answer: …", "Memories, button",
   "Camera view, image" with what is in view, "Status" with its figures. Rest on Camera view and on
   Status for ten seconds each: each should be read once, not repeatedly as its figures change.
9. Touch the caption, the button, the middle of the screen. Each is read. Double-tap with focus on
   the caption: a new description starts.
10. Ask something slow to answer. Expect "Thinking" after a second or two, then the reply.
11. Double-tap Memories. Expect focus inside the sheet, and nothing behind it reachable by swiping.
    Rows read like "Sarah, 3 face samples". Swipe down to "Forget", double-tap: a confirmation
    appears. Dismiss it with a two-finger scrub (or its "dismiss popup" element): nothing is
    forgotten. Scrub again to close the sheet; note where focus lands (expected: Memories).
12. Screen Curtain on (three-finger triple-tap). Describe, ask, open Memories, forget the test
    thing, close. All without sight.
13. Set text size to the largest (D) and get a long reply. A three-finger swipe scrolls the captions.

**B. Braille display**, if one is available (VoiceOver > Braille)

14. Ask a question. Expect the reply to appear on the display as it is spoken. Move to the "Answer"
    element and read the whole reply at your own pace. The button reads "Listening" while listening.

**C. Voice Control, Switch Control, keyboard**

15. Voice Control on. "Show names": the button is named by its title, Describe, and the icon is
    named Memories. "Tap Describe": a description. "Tap Memories", "Scroll down", "Tap Done" all work.
16. "Show actions for Describe", then "Ask a question"; ask; "Tap Listening". Look at the question
    on screen: the stop command is expected in it today (gap 5).
17. Switch Control on, one switch. Scanning stops on Describe and Memories. Selecting Describe
    describes, or offers a menu with Tap and "Ask a question".
18. Bluetooth keyboard, Keyboards > Full Keyboard Access on. Tab reaches Describe and Memories with a
    visible focus ring; Space describes; Tab then Z opens the actions and "Ask a question" works; in
    Memories, Escape closes the sheet and focus is never stuck.

**D. Larger Text** (Display & Text Size > Larger Text, the largest accessibility size)

19. Every piece of text is larger, nothing is cut off or overlapping. Get a long reply: drag the
    captions to scroll back; tap them for a new description; hold on the button to ask.
20. Memories: thumbnails sit above their text, names and details wrap, nothing is truncated.
21. Repeat at one middle size.

**E. Display settings**

22. Motion > Reduce Motion on: the button no longer shrinks when pressed.
23. Display & Text Size > Increase Contrast on, then Reduce Transparency on: the status line, the
    captions and the Memories button have solid black backings.
24. Color Filters > Grayscale: listening, thinking, loading and ready can still be told apart, and
    every tag can still be read.
25. Phone in Light Mode: the app and the Memories sheet are dark. Note whether the launch screen
    flashes white (gap 11).
26. Point at a white wall and at a window: status line and captions stay readable. Run Xcode's
    Accessibility Inspector audit on both screens.
27. Point at a large object the detector is unsure of. If its shading flashes, count: more than
    three flashes a second over a large area fails 2.3.1 (gap 8).

**F. Without sound**

28. Volume to zero. Ask a question, then ask "who do you know?". Everything that would have been
    said is on screen, and listed under Recent in Memories. (A turn that fails shows nothing until
    gap 4 is fixed.)

## Sources, and what was verified where

- Apple's criteria were read on 14 November 2026 from the App Store Connect help pages "Overview of
  Accessibility Nutrition Labels" and the nine "… evaluation criteria" pages under
  `developer.apple.com/help/app-store-connect/manage-app-accessibility/`. They were read through a
  summarizing fetch, so the wording here is paraphrase, and the last two or three thousand characters
  of the VoiceOver and Larger Text pages were not read.
- From the iOS 27.2 SDK headers: what announcement priorities do (`UIAccessibilityPriority`), what
  the "starts media session" and "allows direct interaction" traits are for, and every API name used.
- From Apple's Human Interface Guidelines, Typography: the Dynamic Type sizes behind the percentages.
- **Recalled, not verified against Apple's documentation, and not observable in a simulator:** that
  VoiceOver stays silent after activating a "starts media session" element yet still speaks later
  announcements; that double-tap-and-hold delivers a held touch; where Magic Tap is delivered; that
  VoiceOver sends "announcement finished" for every queued announcement; how announcements appear in
  braille; Voice Control's "Show actions"; what Switch Control puts in its menu. Script A to C exists
  to check exactly these.
- WCAG 2.2 and W3C's "Guidance on Applying WCAG 2.2 to Non-Web ICT" (WCAG2ICT). The WCAG2ICT
  sections for most criteria were read; those for 3.1.1 and 3.1.2 were not, and are applied here from
  memory. "Understanding 2.5.2" was read for the pointer-cancellation decision.
