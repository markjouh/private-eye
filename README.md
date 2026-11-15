# Private Eye

On-device assistant for blind users, for the iPhone 17 Pro. Point the phone, tap or hold, and it tells
you what is there, out loud. Everything runs on the phone. (The Xcode target and folders are still
called `Eyes`.)

## What it does

- **Tap** (anywhere on screen, or click the Camera Control or a volume button): a description of
  what is ahead. One thing held up to the camera is named and its label read: "Water bottle.
  Purified drinking water." Anything else is described as a scene: "Sarah to your right. Laptop
  left, can center, phone right." The app says who is there and which of your own things are in
  view; the language model describes the rest.
- **Hold and speak**: ask a question about what the camera sees. LFM3-VL-2B answers in a few words
  ("Kettle on stove, right."), about the sharpest frame from when the press began, or a sharper one
  that comes while you are still speaking.
- **"Read this"** / "What does it say?": the text in view, read out as printed by Apple's on-device
  text recogniser. **"What is the ID number?"** (any question asking for a number) gets just the
  numbers printed in view, from the same recogniser.
- **"How far is that?"** is answered from LiDAR, in feet: the distance to whatever is straight ahead.
- **People**: "This is Sarah" teaches a face; then "Who is this?", "Where is Sarah?", and descriptions
  use the name. "Forget Sarah", "Forget everyone", "Who do you know?".
- **Belongings**: "Remember this as my water bottle" teaches a thing; "Where is my water bottle?" says
  where it is in view, or where and when it was last seen. Pointed at it, a tap or "What is this?"
  gets "Your water bottle.", or "Possibly your water bottle." when the match is an unsure one.
  Teaching a thing again adds views of it, which is what makes an unsure match a sure one.
- **Crossing questions** ("is it safe to cross?") never reach the model: the reply lists the vehicles
  and signals detected and declines to judge.
- **Action button**: Settings > Action Button > Shortcut > Private Eye > "Describe What's Ahead".
- **Introduction**: every launch opens with the logo, four short notes and the voice settings
  (speaking speed and a choice of up to three voices). It is shown every time because the app is
  being presented; nothing stored is touched. `-onboarding NO` on the launch command skips it, as
  does `-ask`. The same settings are under Memories > Settings.
- **Obstacle haptics** exist but are off by default ("haptics on" / "haptics off"); they need tuning
  on real walks.
- On screen, for sighted helpers and demos: the camera with each detected object's shape shaded and
  tagged with its distance, name tags under recognised faces, and the reply as large text.

Face and belonging memory is one JSON file in the app's Application Support folder. It never leaves
the phone.

## Setup

    brew install xcodegen uv
    tools/setup.sh          # llama.cpp xcframework, model weights, Core ML exports, Xcode project

`tools/setup.sh` covers the detector and LFM3; the two memory models come from
`tools/export_embedders.py` (ArcFace needs `w600k_r50.onnx` from InsightFace's buffalo_l pack in
`tools/work/`; DINOv3 downloads through timm).

Signing: create `Config/Local.xcconfig` with your team and a bundle id of your own:

    DEVELOPMENT_TEAM = ABCDE12345
    EYES_BUNDLE_ID = dev.yourname.eyes

Then run the `Eyes` scheme on the phone from Xcode, or:

    xcodebuild -project Eyes.xcodeproj -scheme Eyes -destination 'platform=iOS,name=<phone name>' \
      -derivedDataPath build -allowProvisioningUpdates build
    xcrun devicectl device install app --device <udid> build/Build/Products/Debug-iphoneos/Eyes.app
    xcrun devicectl device process launch --console --device <udid> <bundle id>

Add `-ask "what is in front of me?"` to the launch command to run one turn without speaking.
The project file is generated: edit `project.yml` and rerun `xcodegen generate` after adding files.

## Testing on the Mac

`EyesCLI` runs the app's own code against image files. Everything under `Eyes/LLM`, `Eyes/Vision`,
`Eyes/Memory` and `Eyes/Haptics` is compiled into it, so those folders must build for macOS.

    xcodebuild -project Eyes.xcodeproj -scheme EyesCLI -configuration Release -derivedDataPath build build
    alias eyes-cli=build/Build/Products/Release/eyes-cli
    M="Models/eyes-ft-v2-Q4_K_M.gguf Models/mmproj-LFM3-VL-2B-Q8_0.gguf"   # stock: LFM3-VL-2B-QAD-Q4_0.gguf
    D="Models/yoloe26m.mlpackage Eyes/Resources/yoloe_labels.json"

| Mode | What it checks |
|---|---|
| `eyes-cli ask $M photo.jpg "Where is the kettle?"` | Model answers. `--batch pairs.tsv` runs a test set; `--system`, `--suffix`, `--side N`. |
| `eyes-cli describe $D $M photo.jpg ...` | The tap description end to end, including whether each photo is taken as one thing or a scene; `--suffix` tries another instruction. |
| `eyes-cli detect $D --out dir photo.jpg` | Detector boxes and mask shading, written as PNGs. |
| `eyes-cli safety "Can I cross now?"` | Which questions are routed away from the model, and every reply built by code: crossing, distance ahead, who is in view. |
| `eyes-cli commands` | Voice-command parser against 99 sentences. |
| `eyes-cli read photo.jpg ...` | Text reading: every line the recogniser found with its confidence, and what would be read aloud (`--numbers`: to a question asking for a number). With no photo, checks which questions are sent to it. |
| `eyes-cli sharp photo.jpg ...` | The sharpness score of each frame, which decides which one the model is given. With no photo, checks that the score falls as a picture is smeared. |
| `eyes-cli faces pairs / identify / engine / tracker / quality ...` | Face verification, identification with strangers, enrol-recognise-rename-forget end to end, the frame-to-frame naming logic, and Vision's quality scores (LFW photos). |
| `eyes-cli things eval ...` | Belonging matching: score distributions, retrieval, threshold trade-offs (Objectron photos). |
| `eyes-cli belongings ...` | Belonging memory end to end: enrol, find, reject look-alikes, rename, last seen. |
| `eyes-cli proximity` | Obstacle-haptics logic on 75 simulated scenes. |

## Debugging a session on the phone

The app records what it saw and did so a test session can be examined afterwards (on by default;
launch with `-debugCapture NO` to turn it off, and do so for demos: the frames show whoever is in
front of the camera). In the app's Caches folder it keeps:

- `console.log`: every console line, timestamped, across launches. This includes system events
  (background/foreground, thermal state, memory warnings, audio interruptions and route changes),
  hardware-button events, who and what is recognised in view as it changes, and for every attempt to
  learn a face or a thing, what each frame showed and why it was or was not accepted.
- `turns/<id>.json`: one per turn: what was heard, which part of the app answered, the reply,
  every detection with confidence and LiDAR distance, faces and
  belongings with match scores, who and what was remembered at the time, the thermal state, and the
  turn's log lines with seconds since the press began (partial transcripts, time to first words).
- `turns/<id>.jpg` the frame the answer came from, `<id>-press.jpg` the newest frame when the press
  began if that was a different one, `<id>-depth.jpg` the LiDAR map (bright is near, blue is no
  reading), `<id>.m4a` what the microphone heard during the press.

The last 250 turns are kept. To copy it to the Mac and draw the boxes on each frame:

    tools/pull_debug.sh <device udid> [bundle id] [--last N]

It writes to `~/Library/Caches/private-eye-debug` (outside the project, which may be cloud-synced),
prints a summary of each turn including the length and loudness of its audio, and puts annotated
frames in `annotated/`.

## Accessibility

`docs/ACCESSIBILITY.md` is a conformance report against WCAG 2.2 A/AA and Apple's Accessibility
Nutrition Label criteria, with the open failures and a manual test script for the phone.

## Layout

    Eyes/AppModel.swift             turn state machine and routing: command, safety, reading, description, model
    Eyes/SceneDescription.swift     what the app says before the model on a tap: people and the user's own things
    Eyes/Surroundings.swift         replies built from measurements: crossing questions, distance ahead, shared phrasing
    Eyes/LLM/                       LLMEngine (LFM3-VL via llama.cpp), AnswerStyle (per-question prompts,
                                    streaming filter, style guide), VLMService (runs it off the main thread)
    Eyes/Vision/                    CameraController (capture + LiDAR), Sharpness, ObjectDetector, MaskShader, DepthMap, TextReader
    EyesCLI/                        the Mac test tool, one mode per file
    Eyes/Memory/                    FaceEmbedder, FaceTracker, ThingEmbedder, BelongingTargeting, MemoryStore,
                                    MemoryEngine, Commands (voice commands), MemoryReplies, PixelWarp
    Eyes/Debug/                     DebugCapture: per-turn frames, audio and decisions for later inspection
    Eyes/Speech/                    SpeechRecognizer (always-on mic, push to talk), Speaker (streamed TTS),
                                    VoiceSettings (speed and voice, kept across launches)
    Eyes/Haptics/                   ProximityModel (obstacle logic), ProximityHaptics (Taptic Engine)
    Eyes/Intents/                   App Intents for the Action button, Shortcuts and Siri
    Eyes/UI/                        preview, mask and face overlays, press surface, hardware buttons, main screen,
                                    OnboardingView, VoiceSettingsControls, MemoryView
    tools/                          export_yoloe.py, export_embedders.py, make_icon.py, setup.sh

## Measured (on the Mac unless noted)

- **Faces** (ArcFace R50 on each face and its mirror image, Vision landmarks for alignment): 99.5% on
  1,000 LFW pairs, the same as a reference alignment. With people enrolled from one photo and as many
  strangers, at 0.35 every known face was named and no stranger was, down to faces 35 px wide;
  different-person pairs never scored above 0.19. The app names at 0.36, says "possibly" from 0.30,
  and ignores faces under 30 px wide (roughly 4 m at the current capture size). On the phone, known
  people on a poor frame scored 0.24 to 0.30, which is why naming is not judged frame by frame:
  `FaceTracker` holds a sure name through weak frames, promotes three probable frames in a row, and
  picks good new angles to store as extra views.
- **Belongings** (DINOv3 ViT-S/16 CLS, tight padded crop): 93% top-1 from one stored view, 97% from two.
  At the 0.70 accept threshold the right object is accepted 87% (one view) to 95% (two views) of the
  time and a different object of the same kind is wrongly accepted 4 to 6%; between 0.60 and 0.70 the
  app says "might be". Plain unmarked objects cannot be told from their twins.
- **Answers**: on a 68-question set, mean length went from 18 words to 4 and correct answers from 59
  to 65 when the style moved to per-question suffixes plus a streaming filter.
- **On the phone**: LFM3 loads in about 1 s, reads a frame in about 0.7 s (it starts when the press
  begins, so it is usually done by the time a question has been spoken), 40 to 50 tokens/s cool and
  about 32 at thermal "serious". Across one session of 54 spoken questions the first words came a
  median 0.26 s after release.

## What the model is given

The frame, the question and a one-line style instruction. Nothing from the detector, LiDAR, the
text recogniser, or face and belonging memory goes into its prompt. That is deliberate, and it keeps the model's input the
same as a plain visual-question-answering set such as VizWiz, should it be fine-tuned on one.

What each other part is for, and the evidence (one session on the phone: 92 turns, with frames):

| Part | Used for | Not used for |
|---|---|---|
| Language model | Every question, and the description of the scene on a tap | Naming people, measuring distance, judging traffic, reading out text |
| Text recogniser (Apple Vision) | "Read this", "what does it say", and questions asking for a number | Any other question, including ones about other text ("what is the expiry date?") |
| Detector (YOLOE) | "Person" (the model leaves people out of descriptions), outlines for belonging memory and face enrolment, vehicles in the crossing reply, the shading on screen | Naming objects in anything spoken |
| LiDAR | "How far is that?", distances in replies built by code ("Sarah, 3 feet ahead"), tags on screen, and whether something is held up to the lens (see below) | Anything the model sees or says |
| Face and belonging memory | Names, "your water bottle", where a thing was last seen | Context for the model |

- **Detector and LiDAR text in the prompt, removed.** Of 52 questions the model answered, one was
  given a context line and no answer contained a distance. Earlier tests had shown the cost: handed
  a list of distances, the model recites them and pins them on the wrong objects.
- **Detector-built description, removed.** On the 37 taps of that session the detector's lists carried
  things that were not there (wallet, handbag, stool, a "white cane" for a cable) and missed what the
  phone was aimed at (cans, a phone, a staircase). The model alone, on the same frames: "Stairs
  ahead, railing left, floor below.", "Laptop left, can center, phone right."; about 6 words against
  17. It never mentions people, so the app says those first: 9 words on average for the whole reply.
  Three of the 37 mention a person twice, once from each source.
- **One thing or a scene: the model is asked.** Tapping while holding up a water bottle used to get
  "Water bottle center, laptop left, cup right". Before describing, the model now answers "Is this
  a close-up of one object?". On all 78 taps saved from the phone its answer matched a person's
  reading of the frame: yes for 29 (things in the hand, a bottle alone on a table, a wall sign, a
  laptop filling the view), no for 49. A yes gets "What is this?" with an instruction to read the
  label: "Red Bull Zero can.", "Emergency rescue assistance sign. Area of rescue assistance 911 in
  case of emergency dial 911." A no gets the scene description, unchanged. Three things were tried
  first and dropped. One prompt covering both cases: every wording that read the label also
  flattened scenes ("Laptop, table."). Deciding from LiDAR or the detector: a bottle in the hand
  and a keyboard under the phone are both 25 cm away. Leaving the yes/no in the conversation: the
  next answer turned curt (the sign became "Elevator."), so the model's state is copied before the
  yes/no and put back after it (9 MB, about 35 ms in all on the Mac).
  This is asked on taps only: a dictated "what do you see?" has said what it is about, and gets
  the scene. A dictated "what is this?" gets the same name-and-label instruction, with no yes/no.
- **People announced by the app are left out of the model's scene description.** Otherwise it
  named one of them again in 12 of 78 such scenes ("Tom ahead. Person center."). Adding "Do not
  mention people." to the instruction took that to 0 of 78 and left the rest of the answer as it
  was; "name the nearest things, not people" also did, but lost the positions ("Table, laptops,
  cans."). With nobody announced the instruction is unchanged, so a person the detector missed
  can still be mentioned.
- **A recognised person, said at once, settles that the tap is about the scene.** Pointed straight
  at someone, the model called them "one object" and described "Person." Rewording the yes/no to
  exclude people was tried: every wording broke something else (one turned 18 real close-ups into
  scenes, another called stairs and blank walls close-ups).
- **Things are never picked out by colour.** "Which one is the hand soap?" got "Orange bottle.",
  no use to someone who cannot see it. The cause was the instruction's own example ("Tall green
  bottle."). Questions that ask for one of several to be picked out now get position and size
  ("Right one, shorter and rounder.", "Left one, taller bottle."), right on all three sharp frames
  of that scene; the general example no longer has a colour in it; and "Is it on the left or
  right?" is answered "Soap on counter, left." instead of "Yes, left." Colour is still given when
  asked for ("What color is the hand soap?" gets "Orange.") and in descriptions of people's
  clothes. An example naming a part ("tall with a pump") was tried first and the part turned up
  on a bottle without one.
- **The label must be the thing's own.** Told to "read any label on it", the model read one off
  whatever else was in view: a sleep mask held in front of a water bottle came back as "Sleep mask.
  Water." four times running, and the back of an ID card as another university's. "If it has a
  label of its own, read it" stopped both on every saved frame. The price: the bottle's label is
  read on 5 of 11 held-up taps where it was 8, and a wall sign is named but no longer read out
  ("read this" does that, exactly).
- **No "Your …" in front of a held-up object.** It said "Your water bottle. Sleep mask." three
  times, with the bottle on the desk behind the mask, and never once fired on 13 taps of a bottle
  in the hand.
- **The user's own thing is the answer when the camera is pointed at it, sure or not.** A jacket
  taught once (three views from the same moment) matched at 0.61 to 0.72 lying crumpled on a desk,
  under the 0.70 that makes a match sure, so its outline was drawn ("your jacket?") while the
  replies ignored it: "Fleece blanket.", "Folded clothes.", and "Red Bull can." for a can beside
  it. Unsure matches are now spoken, as "Possibly your jacket."; all nine saved from the phone
  were on the right thing. Pointed at means the middle of the thing's outline is within 0.15 of
  the middle of the view: in the 23 saved turns with one of the user's things in view it was 0.09
  or less the 6 times the thing was what was being shown, and 0.20 or more the 17 times it stood
  beside or behind that. A tap the model calls a close-up now gets that name instead of the
  model's.
- **Names at once, unless something is held up.** The yes/no costs time on the phone (about 0.23 s
  when first measured), and waiting for it pushed a recognised name from under 0.1 s after a tap to
  0.8 s. So names are spoken the moment the tap ends, except when LiDAR puts the middle of the view
  within 0.45 m: then something is probably being shown to the camera, the names wait for the
  model, and are dropped if it says close-up. On the saved taps that never put a name in front of
  an object's description, and 15 of the 16 scenes with a recognised person got the name at once.
  Strangers ("Person ahead.") and the user's own things always wait: the detector's "person" is
  often the user's own arm around whatever they are holding.
- **Naming the centre from a crop, removed.** It existed to cover for the detector and made taps
  fast (0.36 s), at the price of a second way of reading the frame. A tap now waits for the whole
  frame.
- **Apple's text recogniser for "read this", adopted for that and nothing else.** Asked five times
  for the number on one ID card, the model gave five different numbers, none right. The recogniser
  read the right one in all five frames. On large stylised text the two are about level: it was
  better than the model on two signs, found nothing on an EXIT sign the model read (with nothing
  found the model answers as before), and both mangle a drink can held at an angle. All of this was
  on frames saved at 960 px; in the app it gets the full 1440 px frame.
- **The recognised text as context for the model, tried and not adopted.** It fixed the ID number in
  three of five frames, but the model then answered a different question from the text too ("What
  university is he from?" got the name on the card), and once copied a digit wrong. Same pattern as
  the distances.
- **Questions asking for a number go to the recogniser.** Nobody said "read this" at an ID card;
  seven times out of seven the question was "What is the (student) ID number?". The model was right
  once in seven, usually a digit or two off. The recogniser's number lines on the same seven frames
  were each exactly the number, the same every time for each card. Other questions about text
  ("what is the expiry date?") still go to the model alone and can be wrong.
- **The recogniser reads the frame from the end of the question, not the start of the press.** On
  the phone, five of seven number questions were answered by it (the same, right number each time)
  and two fell through to the model ("Can't read it."): at the start of those presses the card was
  half out of view, and in a third it was blurred from being lifted. The model is given a frame at
  the start of the press, because reading it then is what makes answers fast.
- **The model is given the sharpest recent frame, not the newest.** The newest frame as the button
  goes down is often smeared, the phone still coming to rest: at least 13 of the 245 lit press
  frames saved from the phone were, and the answers about them were wrong ("Blurry photo.",
  "Clothing fabric.", the wrong one of two bottles, which it got right on the three sharp frames
  that followed). A frame's sharpness is one number (`Sharpness`, about a millisecond a frame); the
  smeared frame of the bottles scores 36 and the sharp ones 234, 237 and 246. At the press the model
  gets the sharpest frame of the last fifth of a second. While the button is held, a frame at least 1.5 times
  as sharp as the one it has replaces it, twice a turn at most; reading a frame takes two thirds of
  a second, usually less than the rest of the question. In a session of 23 presses on the phone the
  frame the model ended with was 2.7 to 6.7 times as sharp as the newest at the press in 9, every
  one a question about a person, with the phone still swinging up to them as the button went down:
  the newest frame showed a smeared desk, the one the model got showed the person. Time to first
  words was unchanged (about 0.6 s after release) and the camera ran out of buffers once. A thing
  brought into view after the press, with nothing getting sharper, is still missed.
- **Reading only the largest text, tried and dropped.** It read the name on the card and left out
  the number.
- **Remembering the previous question, tried and not adopted.** With the last exchange put in front
  of the next question, 22 of 41 answers changed, several for the worse ("Restroom sign" became
  "Sink"), and the follow-up it was meant for ("Why not?") was still not answered usefully.
- **Obstacle haptics** are off by default and untuned. They and the LiDAR capture are the parts
  with the least to show for themselves so far.

## Things worth knowing

- LFM3's chat template opens the reply with `<think>` by default. The engine writes
  `<think></think>` so it answers directly; `thinking = true` turns reasoning back on.
- LFM3's memory cannot be trimmed back to an earlier point (`llama_memory_seq_rm` refuses a partial
  removal, because of the model's recurrent state). To ask a second question of the same image
  without the first one in the way, save the sequence state after the image and restore it.
- LFM3 follows an instruction placed after the question and copies the shape of an example given
  there; style instructions in the system prompt are mostly ignored. See `AnswerStyle` for what was
  tried and failed.
- Give LFM3 a list of distances and it treats them as the point of the question, and pins them on
  the wrong objects. It is no longer given any.
- Left to describe a scene, LFM3 skips people. `SceneDescription.known` says them first, from the
  detector's "person" and face memory.
- "Person left." can be heard as someone having gone, so people are placed "to your left"; the
  model's own "Laptop left" is not ambiguous and is left as it comes.
- The detector ranks every (box, label) pair, so one outline can come back under several labels;
  `ObjectDetector` keeps the most confident label per outline.
- The detector's vocabulary is baked in at export. Edit `VOCAB` in `tools/export_yoloe.py`, delete
  `Models/yoloe26m.mlpackage` and rerun `tools/setup.sh`.
- Core ML pads the detector's output rows, so decoding steps by `MLMultiArray.strides`.
- DINOv3 in half precision overflows in its first attention block and was silently wrong on the
  Neural Engine; `tools/export_embedders.py` works around both, and `ThingEmbedder` re-checks a
  reference embedding at load and falls back to GPU or CPU if it does not match.
- Heat matters: at thermal state "serious" with the detector running flat out, generation fell from
  about 45 to 11 tokens/s. The detector is paced (10/s, 4/s when hot, 2/s while the model answers) and
  capture is 1440x1080. Each turn logs the thermal state.
- LiDAR is only trusted to 5 m (16 feet); farther objects get no distance.
- Adopting the hardware capture buttons means the volume buttons no longer change volume while the
  app is open (Control Center still does).
