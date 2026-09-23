# Changelog

Every released version of Subtitles, newest first. Dates are the release commit's.
Versions are the `VERSION` at the top of `build.sh`, which is what the About panel
and the DMG name show.

## 1.10.1 · 2026-09-23

- **The ⌥ history steps back a text size.** Its boxes are set one size
  below the live box: 17 points under Small, 22 under Medium, 30 under
  Large and 40 under Huge. The stack reads as behind the caption rather
  than beside it, and holds more of what was said in the same room. The
  search field and the Settings preview follow.
- **Lines stop at 84 characters.** Every box now sets lines of at most 84
  characters at its own text size, and the live box takes at most three
  quarters of the screen's width, in place of 70% of it or 1,100 points.
  At Small the lines are shorter than they were, at Large and Huge longer
  on a wide display, and the history's boxes, at their smaller size, are
  narrower than the live box.
- The welcome window's demo glows with its desktop's light, as the site's
  does, fading out into the window's margins.

## 1.10.0 · 2026-09-23

- **The new speaker's first words go in their own box.** With **New box on
  speaker change** turned on in Settings, the diarization model only knows
  someone else is talking a second or two after they start, so their first
  words used to end the outgoing speaker's box, on screen and in the ⌥
  history. The change now carries the moment the new voice began, according
  to the diarization, and the break goes there: at the end of a
  sentence or the pause between the two voices, whichever is nearest. Words
  already on screen move to the new box; words in a box that had already
  closed are taken back out of it in the history, and join the box on
  screen or, if the box had faded, become a box of their own. A voice has
  to hold for half a second before it counts as a new speaker, so a cough
  or a quick "mm" no longer breaks the page. With translation on, the
  translated box breaks at the same point once its words there have
  settled.
- The ⌥ history follows you across Spaces. Stop the audio on one desktop,
  move to another and hold ⌥: the history now opens there, as the live box
  always did, rather than on the desktop where it was last shown.

## 1.9.0 · 2026-09-22

<!-- [0bsd-edition]
- Nothing changes in this edition. The main edition gained free minutes
  after its trial; this one has no trial, by design.

[/0bsd-edition] -->
<!-- [main-edition] -->
- **Free minutes after the trial.** When the seven-day trial ends, the app
  no longer stops captioning for good. It captions for five minutes, then
  rests for thirty, and starts again, for as long as it runs. The five
  minutes start with the first caption, so a quiet Mac or a model still
  loading uses none of them, and once started they run on the clock
  whether or not anything more is said. When they are up, the box says so
  itself, under the app's own name and icon: "Your trial has ended,
  captions will resume in 30 minutes." and, on the line below, "Get a
  license key at subtitles-live.com", drawn in word by word like any
  caption, with Audio Borealis still following the sound. Click the box
  while it shows to open the store. During the rest the status menu says
  when captions resume and Resume opens the license window, as it did;
  quitting does not cut a rest short, and a key entered at any point ends
  it at once.

<!-- [/main-edition] -->
## 1.8.4 · 2026-09-21

- The name on the box follows the words in it. Under All System Audio, when
  a second app starts playing, the app listens to it for three seconds, as
  it did, and now asks its voice detection whether there is a voice in what
  it hears and, under the Multilingual model, transcribes that moment on its
  own and holds the words against the ones on screen. An app heard saying
  the words on screen takes the box's name and icon; one heard playing
  music, with or without lyrics, or any voice other than the one being
  captioned, does not, however long it plays, so a playlist started during
  a call leaves the call's name on its words. It is listened to again every
  twenty seconds in case that changes, hold music becoming the call. When
  the app whose words were on screen stops, the box falls to an app heard
  speaking before one heard playing sound, and to that before one heard
  silent; and an app heard speaking keeps the box against one that could
  not be listened to, which used to take it after thirty seconds. The
  captions themselves are untouched: the check runs a second recognizer
  over the same loaded model, on the app's own audio, for a fraction of a
  second on the Neural Engine per listen. Under the other models the check
  stops at a voice, and with Skip non-speech off in Settings, or while the
  model is still loading, sound counts as words as before.

## 1.8.3 · 2026-09-21

- **Color Theme**, in the status menu above Audio Borealis: Auto, Light or
  Dark. Dark is the box as it has always been, black with white type. Light
  turns it inside out: white with dark type, the app's name in the tab or
  header black at half strength, and the hairline a shade darker than the
  box rather than lighter, as the site's demo draws its light box. Auto,
  the default, follows the system's appearance, so a Mac in light mode now
  gets light boxes; choose Dark to keep them black. The recent boxes on ⌥
  and their search pill wear the same theme, caret included, and so does
  the Settings preview.
- **Monochrome Haze** is White Haze's new name in Audio Borealis, and the
  haze is now the opposite of the box's color: white on the dark box, a
  dark gray on the light one. A copy that had White Haze chosen keeps its
  choice under the new name.

## 1.8.2 · 2026-09-20

- **Audio Borealis**: color along the bottom of the box that rises and falls
  with the sound. Soft lobes fan out from the edge, each following a band of
  the voice, and over them one translucent curve per band, lows to highs,
  lifts as its band is heard, so a vowel and a sibilant move different
  hills. Silence is nothing; a voice makes it pulse with the syllables. It
  follows whatever the app listens to, an app's audio or the microphone
  alike, scaled to its own peaks so a quiet voice across a desk fills the
  same range a film's soundtrack does. On by default, in the new Audio
  Borealis submenu of the status menu: Off, or a look (Rainbow, Northern
  Lights, Autumn, White Haze) and a strength (Strong, Medium, Subtle).
  Rainbow and Medium unless you choose otherwise.
- The welcome window's demo glows the same way, and follows the look and
  strength you pick.

## 1.8.1 · 2026-09-19

- Safari's audio is Safari's. Safari plays through a WebKit service that
  carries neither its bundle id nor its name, and every WebKit app (Mail,
  Raycast, the rest) runs an instance of the same service, so the box wore
  the name and icon of whichever instance the app found first: "Raycast
  Graphics and Media" for a video playing in Safari, and picking Safari in
  Listen To tapped every one of them. A process is now attributed to the
  app that answers for it, as the system sees it (the same answer a
  permission prompt gives when a helper asks for the microphone): Safari's
  service to Safari, Firefox's plugin container to Firefox, a Quick Look
  preview to Finder. The box wears the app's own name and icon, and picking
  the app in Listen To taps just what plays for it. A copy that had Safari
  chosen under the old name falls back to all system audio once, with a
  line in the log; choose Safari again.
- Listen To names apps exactly as the box does. The rows used to carry the
  number of processes behind an app, "Google Chrome (3)", which read as a
  different name from the box's; the count is gone.

## 1.8.0 · 2026-09-19

- **Listen To** has the microphone: whichever input Sound settings has,
  followed when that changes, named in the menu as Sound settings names it.
  The boxes wear a white mic on a red tile as their source, and the choice
  is remembered across launches. macOS asks for the microphone the first
  time it is chosen and not before, never at launch, and a refusal opens
  System Settings at the microphone list. A microphone is mono and not
  always 48 kHz, where the taps are 48 kHz stereo, so the audio core is
  rebuilt for whatever format the input has, on the way in and on the way
  back. Sentences on it end after a second without speech rather than
  waiting for the room to fall silent, which a microphone never hears.
  Choosing the microphone row again puts it away: capture goes back to the
  source it replaced, or to all system audio.
- **Show Both Languages**, under Off in Translate To. With it on the box
  carries two paragraphs: the Translate To language on top as the caption,
  the other language under it in a smaller, dimmer run. When the target
  language itself is spoken the pair reverses, the speech as the caption
  and the translation under it, with its unsettled tail dimmed as the
  caption's is and following Translation Timing the same way. The same
  language never appears twice: the lower paragraph is only ever the words
  the translation was made from, never the live transcript, and a sentence
  the translator returned unchanged is left out. A page turns when either
  paragraph fills, and is held long enough to read the slower of the two.
  Each box in the ⌥ stack keeps both texts as it showed them. ⌃ does
  nothing while both are shown: there is no original left to peek at.
- A box in the ⌥ stack is as tall as what it holds. The live box is capped
  at Lines per box and the stack's boxes used to be cut at the same height,
  which lost the end of an original shown under ⌃ (the page was cut on the
  translation, not on it) and of a page closed at a smaller text size.
- Translation works in turns. The recognizer keeps one transcript across a
  conversation, and finishing a sentence used to rewind and re-translate all
  of it; now a pause or an endpoint closes a turn, words arriving while it
  settles wait for the next, and changing the target re-translates only the
  current turn. A tail dimmed as unsettled no longer stays dimmed for good,
  and a request the translator leaves unanswered for ten seconds is sent
  again.
- The welcome window's demo listens where the app does and shows both
  languages when the app does, from the moment it opens and as either is
  changed, with the menu bar's orange microphone pill up while it listens.
  Its boxes sit at the app's line height, as the site's now do.
<!-- [main-edition] -->
- The question about checking for updates automatically is asked as the
  welcome window closes, in that window, rather than at the second launch. A
  first-time user closed the welcome and heard nothing about updates until
  the next day's relaunch. It is still the one question, asked once.
<!-- [/main-edition] -->

## 1.7.2 · 2026-09-17

- The welcome window's demo draws the box you have. It opens seeded with the
  overlay's settings — the text size and alignment, the header row or the
  name tab, how many lines a box fills before it pages, how solid it is and
  how far the picture under it is softened, the pointer reveal, how many
  boxes ⌥ keeps and when it forgets them — and follows a setting as it is
  changed, in place, from the menu or from Settings. The demo's own menu
  still works on it, and the last change wins whichever side made it: a size
  picked in the demo survives the app's blur changing, and a size picked in
  the app takes over one picked in the demo.
- The welcome window is 150 points wider, and its demo with it.
- The demo's windows are drawn the way macOS 26 draws them, as they are on
  the site: rounder frames with a fine rim, sidebars as glass panes with the
  traffic lights in them, a call's controls in a capsule over the tiles, the
  app's menu on the same glass. The call in the Settings preview follows the
  same drawing, and the keycaps the demo types into its boxes are outlined,
  as the welcome window's own are.
- The Settings preview follows a change made from the menu while the window
  is open — the text size, the pointer reveal, the ⌥ stack — and its switches
  with it. It used to catch up when the window next became key.
- The ⌥ stack's fades at its clipped edges ease in and out rather than
  ramping straight, on the overlay and in the Settings preview alike.
<!-- [main-edition] -->
- The license window says Buy a Key without naming a price: the price is
  set on Gumroad, and a number in the app went stale the moment it changed.
<!-- [/main-edition] -->

## 1.7.1 · 2026-09-14

- A notification sound no longer puts its app's name on the box. Core Audio
  reports an app as playing for as long as it holds an output stream open,
  not for as long as it makes sound, and a notification holds one for
  seconds after the ding: about two in a native app, ten in a Chromium-based
  one such as Slack or Discord, and for a whole burst of messages the stream
  never closes at all. So a message arriving during a video renamed the box
  after Slack for ten seconds, and a busy channel kept it there. The rule
  from 1.7.0, that a newcomer had to be playing for two polls running, was
  written for a ding that lasts half a second, which none does.
- Now a newcomer is listened to before it can take the box. Two seconds
  after an app starts holding a stream, by which time its own ding is over,
  the app taps just that app for three seconds and counts how much of it
  clears a floor of −55 dBFS; only sustained sound earns the name. A ding
  reads as silence and changes nothing, a burst of dings likewise, and an
  app heard to be silent is listened to again twenty seconds later in case
  the burst became a call. A call that starts while a video plays is named
  within about six seconds, where it used to take two and now takes the
  measuring. An app nobody managed to listen to takes over after thirty
  seconds, as a backstop; one heard silent never does, however long it holds
  its stream. When the named app stops, the box falls to the best of the
  rest, never to one heard to be silent.
## 1.7.0 · 2026-09-13

- Every box says which app it is transcribing. A row inside the box carries
  the app's icon and name above the caption, the way Live Captions heads its
  box; **Show Source App Name** in the menu swaps it for a tab on the box's
  top edge, or turns it off. With all system audio selected a box gave no
  hint where its words came from, and the ⌥ stack could hold a call and a
  video with nothing to tell them apart.
- Each box in the ⌥ stack wears the app its words arrived under, not the app
  of the words that closed it: a box that faded during a call stays the
  call's when a video's first words open the next one. Icons in the stack
  keep their full color, since a dimmed icon reads as a disabled app rather
  than an older box.
- Under all system audio the app is worked out from what Core Audio reports
  playing, and that is a noisy answer: browsers hold the audio device open
  with a video paused, and a notification sound is an app playing for half a
  second. So the choice is sticky, and nothing takes it over until it has
  been playing for two polls running. With one app chosen as the source, it
  is that app. Polled once a second, off the main thread.
- Text starts from its script's leading edge rather than being centered: the
  left for most languages, the right for Arabic and Hebrew, where the tab or
  header sits on the right with it. The box fills a word at a time, and a
  line that grows from a fixed edge is easier to follow than one re-centered
  on every word. **Text Size and Alignment** in the menu offers **Center
  Alignment** for the old look.
- A hairline round every box, one pixel wide, the way the system edges its
  own panels: a shade lighter than the box in dark mode, a shade darker in
  light mode, where the picture behind is bright and a light rim read as a
  glint rather than an edge.
- Box corners are 16 points, from 14. The name tab shares that radius, sits
  flush with the box's edge over a squared corner, flares into the top edge
  through a concave foot, and is blurred with the box; the ⇧ ring traces box
  and tab as one shape.
- The ⌥ stack's fade at its clipped edges takes the blur down with each box.
  It used to leave the blur whole under a box that had faded, which read as
  a frosted band where the stack was cut.
- Re-vendored the site's demo for the welcome window, whose boxes name their
  app the same way and whose first scene drops the app's menu. Three things
  in it are fixed on the way: the boxes' icons show, where the script had
  named them by a path only a web server could resolve; the translation
  scene no longer stops for good on the line that invites ⌃, which threw on
  a flag the vendored script was missing; and in Safari's engine a window
  no longer paints its content into the one in front of it for a few frames
  after the scenes have been switched by hand, since each window renders to
  a layer of its own. The settings preview's call is a Google Meet call now,
  with the icon the site draws it with.

## 1.6.5 · 2026-09-12

- The menu is shorter. **Skip non-speech** and **New box on speaker change**
  live only in Settings now, under Models, where they already had switches:
  each one reloads the engine, which is not a thing to flip from a menu while
  watching. **Reset Overlay Position** sits in a group of its own, apart from
  the toggles above it.
- **Acknowledgements** is a button in the About window rather than a menu
  item, beside a new **Changelog** button that opens the site's changelog. It
  opens a window of the app's own instead of a text file in another app: the
  third-party notices, reflowed into paragraphs and set in the app's type, in
  a soft box that scrolls.
- Translation starts as soon as it is turned on. It used to wait for the
  recognizer to name the language it was hearing, which the multilingual model
  does at the start of a sentence rather than on the first words, so captions
  that began mid-sentence, or a target picked in that stretch, went
  untranslated until the next full stop. The language is read off the
  transcript itself until the model names one, and turning translation on or
  changing its target starts the recognizer afresh, so the next words open a
  new box in the new language instead of finishing the old one.
<!-- [main-edition] -->
- The trial ending puts the same red badge on the menu bar icon that a
  waiting update does, so it is seen without opening the menu. The badge is
  never dimmed: pausing fades the icon, and used to fade the badge with it.
  An update and an ended trial at once show a 2.
- The update window's release notes box shows in light mode now; its gray was
  too faint to read as a well. It also takes its color when drawn rather than
  when the window is built, so a window open through a change of appearance
  gets the right one.
<!-- [/main-edition] -->

## 1.6.4 · 2026-09-12

- The picture behind the boxes is blurred, six points of it. Dark text on a
  dark pill over a busy scene was hard to read, and softening what is under
  the box is what lets the text stand off it. The live box, the ⌥ stack and
  its search field all have it, and the pointer reveal cuts through the blur
  exactly as it cuts through the pill, so what shows through the hole is the
  page itself, sharp.
- **Blur**, under Background in Settings, sets how far the picture is
  softened, from off to twenty points, and the preview follows the slider.
- Re-vendored the site's demo for the welcome window, whose boxes wear the
  same blur.

<!-- [0bsd-edition]
## 1.6.3 · 2026-09-09

- ⌘V pastes into the Clear After field in Settings now, and ⌘C, ⌘X, ⌘A and
  ⌘Z work there too. They reach a text field only as the key equivalents of
  an Edit menu, and an app without a menu bar has no Edit menu unless it
  makes one; it has one now, which nothing ever shows.

[/0bsd-edition] -->
<!-- [main-edition] -->
## 1.6.3 · 2026-09-09

- A license key can be pasted into the license window now. ⌘V, and ⌘C, ⌘X,
  ⌘A and ⌘Z with it, reach a text field only as the key equivalents of an
  Edit menu, and an app without a menu bar has no Edit menu unless it makes
  one; it has one now, which nothing ever shows. The Clear After field in
  Settings takes a paste for the same reason.

<!-- [/main-edition] -->
## 1.6.2 · 2026-09-08

- Re-vendored the site's caption demo for the welcome window. The screen is
  16:9 now, menu bar included, and the model a tenth smaller so each window
  still holds what it held. The apps go by the names the Mac shows, zoom.us
  and Spotify, the ⌘-tab switcher wears their icons, and the Notes window is
  drawn as Notes: the toolbar in its title bar, the list beside the note.
- The welcome window's copy of the demo carries those icons and the Notes
  window's styles itself. The site names the icons by absolute path, which
  in a webview loading a file would have pointed at the root of the disk, and
  keeps the Notes styles with the landing pages' windows rather than in the
  demo's own section; the vendor script now brings both across.
- The screen's corner in the welcome window follows the site's own rule,
  which is set from the model's unit and clears the Apple mark and the clock
  at this width, rather than a radius the window forced on it.

## 1.6.1 · 2026-09-08

- The ⌥ stack no longer shifts sideways when a box arrives that is wider than
  the ones already up, or when the widest one leaves. The stack is as wide as
  its widest box, so its left edge moves at those moments; what moved with it,
  for a tenth of a second, was every box in it, because the edge was what the
  stack's follow animation was attached to. It is attached to the center now,
  and each box is placed from that center rather than centered in the stack, so
  the stack's width can change under them without a box moving by a point.

<!-- [0bsd-edition]
## 1.6.0 · 2026-09-07

- Nothing changes in this edition. The main edition gained a free trial and
  license keys; this one has neither, by design.

## 1.5.0 · 2026-09-07

- Nothing changes in this edition. The main edition gained an in-app updater;
  this one has none, by design, and is updated by downloading again.
[/0bsd-edition] -->
<!-- [main-edition] -->
## 1.6.0 · 2026-09-07

- The app is a free download with a seven-day trial, and a license key is what
  you buy. The trial starts when the captions do, not at the first launch, so
  the model download does not count against it. When it ends the app keeps
  running but stops transcribing: the icon dims as it does for Pause, the menu
  says why, and Resume opens the license window instead. Settings and the ⌥
  stack stay where they were.
- **Enter License Key…** sits above Settings, or reads **Trial: N days left**
  or **Licensed**. The window takes the key as it was pasted from a receipt or
  the Gumroad library, in any case and spacing, and says in place what became
  of it. Activating sends the key to Gumroad once; the app checks it again,
  silently, about once a month, and only a key Gumroad reports as refunded,
  charged back, disputed or disabled stops working. A key entered with no
  network is accepted for 72 hours and confirmed when the network is back.
  **Buy a Key** and **Where Is My Key?** go through subtitles-live.com.
- Copies bought before this version are licensed as they are: a copy with
  preferences from an earlier build on its first launch as 1.6 asks for no key.
  Your key is in your Gumroad library for a clean reinstall.
- About says who the copy is licensed to, and Welcome mentions the trial.
- `--verify URL` points key verification at another server, for trying
  activation against a local one, as `--feed` does for updates.
- The DMG is on the GitHub release again, as `Subtitles.dmg` under a name that
  never changes, which is what the site's download button links.

## 1.5.0 · 2026-09-07

- The app can update itself. **Check for Updates…** sits at the top of the menu,
  under Pause; it asks subtitles-live.com for a newer version and installs it
  in place, same location and same signature, so the audio permission survives
  an update the way it survives a rebuild. On the second launch the app asks,
  once, whether it may check on its own once a day; the request carries the
  app's version and nothing else, and the answer is a checkbox in the menu
  afterwards.
- Updating happens in one window of the app's own, in the style of its About
  and Welcome windows: the notes set as text, one progress bar for the download,
  Install and Relaunch when it is ready. A check that finds something opens it
  at launch, or once nothing has been playing for a couple of minutes. While
  something is playing it does not: a red badge with a 1 appears on the icon,
  the menu offers **Update to …**, and the window comes when that is chosen.
  A critical fix opens the window regardless, and cannot be skipped.
- `--feed URL` points the check at another appcast, for trying an update against
  a local server.
- Copies older than this one have no updater. They are updated by downloading
  again, once.
<!-- [/main-edition] -->

## 1.4.3 · 2026-09-06

- The ⌥ stack fades its near edge too, once you have scrolled away from the live
  box: a short band, 60 points against the far edge's 150, saying newer boxes are
  hidden there. It is gone the moment the stack is back against the live box, so
  the newest box is never dimmed while you are reading it. The settings preview
  and the welcome window's demo do the same.

## 1.4.2 · 2026-09-06

- The settings preview's screen is the demo's again: its colored desktop, a menu
  bar with this app's glyph and the clock in it, and a call in front with the ring
  handed round whoever is talking. The ⌥ stack stops at the menu bar, as on a real
  screen. The preview is a little taller.
- The welcome window's demo searches the ⌥ stack, as the site's does. A vendored
  copy without that had nothing to attach the search to and stopped on load.

## 1.4.1 · 2026-09-06

- ⌥⌘S pauses again while the ⌥ stack is showing. The stack's own ⌥F shortcut,
  new in 1.4.0, was swallowing every other shortcut for as long as it was up.

## 1.4.0 · 2026-09-06

- The Keep slider in Settings runs one stop further, to Unlimited, shown as ∞,
  and that is now the default. There the ⌥ stack keeps every box that closes, up
  to two thousand, rather than the last fifteen. Only the count changes: how long
  a silence forgets the stack is the setting it always was, and the two are not
  tied to each other.
- The ⌥ stack can be searched. A small field sits at the edge of the stack
  touching the live box, styled as one more box. Click it, or press ⌥F while the
  stack is up, and type — ⌥ is stripped from what is typed, so the first letters
  can go in with it still held. Typing narrows the stack to the boxes containing
  the text, ignoring case and accents, lights the matches and scrolls to the
  newest one; a circled ✕ at the end of the field clears it. While the field has
  the keyboard the stack is pinned: it stays up with ⌥ released, clearing the
  field to try another word keeps it, and pages that close meanwhile join it and
  are filtered the same way. Escape or a click anywhere outside the stack unpins
  it, and the stack goes back to living under ⌥; a filtered stack fades out as it
  was, and comes back whole.
- The stack no longer re-measures every box each time it is rebuilt. It was a
  hitch at the depths the slider now allows.
- The stack follows the live box on a spring. The box grows a line at a time as
  a sentence wraps, and the stack used to jump the line with it; now it catches
  up over a tenth of a second, while the box itself stays exactly as it was.

## 1.3.5 · 2026-09-05

- In the welcome window's demo, a window no longer jumps when you click it to
  bring it forward.
- The demo's notes window writes while it is in front, as the site's now does, and
  its windows carry the thin ring macOS draws around a real one.

## 1.3.4 · 2026-09-03

- Re-vendored the site's caption demo for the welcome window. It brings the demo's
  menu bar — the Apple mark, the app in front, the first menus — and a desktop
  with some color in it, along with the waveform fitter the podcast scene now
  relies on, which the vendor script had been leaving behind.
- The demo screen's corners are tighter in the welcome window than on the site,
  so they no longer crop the Apple mark at one end of the menu bar and the clock
  at the other.

## 1.3.3 · 2026-09-03

- Choosing a target language whose pack is not installed now asks for it. It used
  to produce nothing at all: no download, no prompt, and the original left on
  screen. The translator was being built without a source language, and without
  one it cannot tell whether a pair needs downloading, so it never asked.
- The language the recognizer detects is remembered rather than only reported when
  it changes. By the time a target is picked, the detection that matters is usually
  minutes old and will not happen again, which is what left the translator with
  nothing to go on.

## 1.3.2 · 2026-09-03

Text no longer comes back after a pause.

- A box that has faded leaves nothing behind. Words from before it were turning up
  at the top of the next box, and that box then kept filling without ever turning
  over. Whatever the translator still owes for a faded box is dropped with it.
- A clause the speaker never finishes now settles on length as well as on age, so
  a box fills and turns over instead of growing forever. Text that has not settled
  yet cannot be paged at all, because it is retranslated whole on every update and
  its words shift each time, so a page break inside it does not stay put.
- Pages break at the edge of the unsettled text rather than inside it, which is
  what made the same few words appear in three boxes in a row while nothing new
  was said.

## 1.3.1 · 2026-09-02

Fixes for the translation overlay shipped in 1.3.0, and a test suite for the
paging logic underneath it.

- Holding `⌃` no longer brings back a caption that had already faded. The stored
  transcripts outlive the box on purpose, since that is what makes the language
  swap instant, but a repaint is not new speech and should not put an old caption
  back on screen.
- Toggling `⌃` repeatedly no longer eats the transcript. Each repaint re-paged
  from the top and consumed carry state as it went, so every toggle broke the
  pages somewhere new and left the box further along than it found it. The
  anchor is now kept across a swap, which is both correct and idempotent.
- The `⌥` stack shows up when the audio is already in the target language.
  Translating a language into itself is refused outright by the framework, so
  the box falls back to the original; the stack was still pointed at the empty
  translated stack and showed nothing at all.
- The stack expires again after its grace period. The same oversight left the
  check looking at whichever stack was visible, so with a target chosen it could
  sit on an empty one and never clear the other.
- Boxes reach the stack when they leave the screen, not a clause later, and no
  longer repeat words the box below already shows. The box and the stack are the
  same boxes seen at different moments, and each used to decide where the pages
  fell for itself; they agreed until something moved one of them, and holding `⌃`
  moved exactly one. There is one page break now, and both read it.
- Switching translation on or off clears the box, rather than leaving half a
  sentence in the language you just left until new words push it out, and turning
  it on no longer flashes a line of the original before the first translation
  lands.
- The box fills with the words still being spoken and turns over when it is full.
  The unsettled tail used to take room without being paged, so it pushed out
  clauses you had not finished reading and replaced itself instead of filling the
  box.
- The overlay never sits blank waiting on a translation that is not coming. It
  shows the original instead, immediately when translation is known to be idle,
  and after a few seconds otherwise.
- The stack holds still. It followed the live box's frame, which rounds its
  origin and hugs its text, so its midpoint moved by a point as the width changed
  parity and the stack stepped sideways on every word. It now hangs off what the
  box is anchored to.
- Swapping the stack's language with `⌃` redraws it in place. Every box changes
  text at once, so the usual rule of animating only what is new staged the whole
  stack in again on a keypress. Opening and closing still animate.
- A clause is carried into the next box and no further, and never out of a box
  that has already faded.
- A stored setting that makes no sense no longer breaks the overlay. A negative
  history depth used to ask the stack to drop more boxes than it holds, which
  crashes, and a box allowed zero lines could never fit a word so it never paged
  and simply clipped. Both are clamped where they are read.
- `swift test` covers the caption pipeline: 75 cases, most of them a bug that
  shipped. Paging is covered from both ends, the box and the `⌥` stack; the model
  cache's deletion is tested against a temporary directory, since it is the only
  code here that removes anything and it removes gigabytes; and the language table
  is pinned, including the count the model menu writes out and the six languages
  the pruned vocabulary pack actually covers.

## 1.3.0 · 2026-08-31

**Live translation, on device.** Captions can now be translated as they are spoken,
into any of the sixteen languages the picker already offers. It runs through Apple's
Translation framework, so nothing leaves the machine and the app keeps the property
it was built around.

- Every ordered pair works, not just the ones involving English. That is what ruled
  out doing this in the recognizer: NVIDIA's canary checkpoint translates speech
  directly, but only to or from English, and half this app's languages are not in its
  set at all. Apple's covers all 240 pairs of the sixteen.
- Two timings, because the interesting cost is not compute. Translating a sentence
  takes 40 to 125 ms here, so the only real question is what to show while a sentence
  is still being spoken. *Live, Then Settle* translates the last second of speech on
  every update and dims it until it settles. *Always Live* retranslates everything
  each update: no lag, and anything on screen may still change.
- Whole clauses are translated, never the box. The overlay breaks pages wherever the
  text happens to overflow, which is routinely mid-sentence, and a fragment translated
  alone loses the case, the gender agreement, or the verb it had not reached yet.
  Translation units and display units are now separate things.
- Boxes overlap by a clause when translating. A page that fills up restarts at the
  last clause it showed rather than at the word that spilled, so there is something
  to re-anchor on when the box turns over instead of a hard cut. Only from a box
  that turned over quickly: one that sat there long enough to be read already gave
  you that time.
- On auto-detect the source language comes from the recognizer's own language tag
  rather than from asking the translator to guess per sentence. It is known within a
  word or two of speech.
- Hold `⌃` to see the original language, live box and `⌥` stack together, for as
  long as the key is down. Translation carries on underneath, so letting go shows
  current text rather than a snapshot. Each language keeps its own page memory, so
  the stack never mixes the two, and a stacked box holds only what it added rather
  than repeating the clause carried into the box below it.
- Translation needs macOS 15. The rest of the app still runs on 14.2, where the menu
  simply does not appear.

**A ghost mode for screen sharing.** "Show Overlay In Screen Share / Capture", on by
default, and unchecking it takes the overlay out of anything capturing through macOS:
calls, recordings, screenshots alike. The `⌥` history stack goes with it. It is not
a promise against a camera pointed at the screen.

**Interrupted model downloads repair themselves.** A download that stopped partway
left a compiled bundle that CoreML refuses, and nothing ever retried it: the model
failed to load on every launch from then on, with no transcript and nothing on screen
to say why. Those bundles are now detected and refetched, and only the broken ones, so
a variant whose encoder alone is truncated costs one encoder rather than 600 MB.

- A recognizer that cannot load says so in the menu, in red, instead of leaving
  "listening" or "no audio" on screen. Both were wrong, and both pointed away from the
  cause.
- `--list-models` reports incomplete bundles too, which is the one way to ask what is
  on disk without starting anything.

## 1.2.0 · 2026-08-30

**Sixteen languages in the picker, up from eight.** The multilingual checkpoint is
`nvidia/nemotron-3.5-asr-streaming-0.6b`, by way of FluidInference's CoreML
conversion, and it reaches 40 language-locales. The menu listed eight of them. It now
carries NVIDIA's transcription-ready tier: Dutch, Turkish, Russian, Arabic, Hindi,
Korean, Vietnamese and Ukrainian join English, Spanish, French, Italian, Portuguese,
German, Mandarin and Japanese.

- The eight new entries need no download. They live in the full-vocabulary pack that
  auto-detect already fetches, so for anyone on the default they cost nothing, and
  moving between them is instant.
- What this adds is pinning rather than reach. Auto-detect already decoded these and
  tagged them itself. Telling the model the language is the more accurate setting
  when the audio is one language: upstream measures Hindi at 7.05 WER told against
  9.26 detected, at the 560 ms tier this app runs.
- Script is not the split between the two packs. Dutch, Turkish and Vietnamese are
  Latin-script and still take the 633 MB one, because the pruned vocabulary was built
  for six named languages and covers nothing past them.
- Every surface now counts languages the same way: `auto` is a detection mode over
  the languages, not one of them.

## 1.1.4 · 2026-08-22

**A settings window with a live preview of the overlay.** The UI pane opens onto a
small screen of its own, because half of what that pane governs describes something
not currently on screen: boxes that have already finished, a hole that follows a
pointer busy holding a slider.

- The preview instantiates the overlay's own views and scales them through a bounds
  transform rather than by shrinking a font, so every proportion comes down together.
  Its captions are scripted: the live transcript is empty exactly when the window is
  open.
- Touch a control and the preview says what that control does, with its current value
  in the sentence. The Recent Boxes controls raise the stack the way ⌥ does, and ⌥
  itself works in there too.
- Windows that do not fit the screen scroll rather than running off the bottom of it,
  where there is no title bar to drag them back by. Settings keeps its header put;
  Welcome re-fits as the demo reports its height and as displays change.
- The welcome demo's web view had been swallowing every wheel event whether or not its
  page had anywhere to scroll. It now hands the event to the window, unless ⌥ is down.
- The overlay follows a resolution change instead of waiting for the next word to
  notice one.

## 1.1.3 · 2026-08-20

- Re-vendored the caption demo from the site, mostly the ⌥ stack learning not to fight
  the caption history's own scroll container.
- Fixed the vendor script's guards, which all looked at the start of each slice, so a
  section that had grown a new tail satisfied every one of them and vendored a demo
  with its newest half missing, silently. Each range is now checked at the line it
  stops on too.
- The welcome screen says what the pointer does before what the modifiers do, and every
  line of that block is a keycap tall whether or not it holds a key.

## 1.1.2 · 2026-08-19

- Re-vendored the site's caption demo: the ⌘-tab switcher, the scrolling caption
  history and the ⌥ stack it had grown since 1.1.0.
- The welcome screen says what the two modifiers do and what the pointer does, one line
  each. `KeycapView` watches the modifier it draws rather than always ⇧, so the ⌥ cap
  lights up for ⌥.

## 1.1.1 · 2026-08-19

**The ⌥ stack forgets after a spell of silence.** It had been answering with whatever
was last said, however long ago: press it after lunch and the stack was still the
morning's meeting. It now clears after 30 seconds with no new text, configurable, and
switchable off.

Measured from the last text rather than the last audio: a backing track holds the voice
gate open indefinitely, so "is the room quiet" is the wrong question. It will not fire
while the stack is on screen, since somebody holding ⌥ is reading it.

## 1.1.0 · 2026-08-19

**Hold ⌥ to bring back the last few boxes, and a settings window to tune them.** The
overlay pages like broadcast subtitles. It fills, clears, starts again, so a sentence
you glanced away from was simply gone. The last few closed pages now stack above the
live box, scrollable when the stack is taller than the room above it.

A second panel rather than a taller live one: the live pill carries the cursor reveal,
the ⇧ drag ring and the hugging resize, all written against there being exactly one
box. Pill geometry moved to `Pill.swift` so the two cannot drift.

## 1.0.3 · 2026-08-17

- Point at the subtitle box and it dissolves around the cursor, so whatever it covers
  can be read without moving it. Hold ⇧ and it goes solid again, which is also when it
  becomes grabbable.
- Re-vendored the welcome demo from the site, bringing its I18N with it.

## 1.0.2 · 2026-08-16

- A welcome screen for first launch, which downloads ~600 MB before a single caption
  can appear. Until now the app's entire first impression was a menu bar icon with a
  dot on it.
- An About window of its own, after a first pass at AppKit's standard panel.

## 1.0.1 · 2026-08-16

- A dashed ring while ⇧ makes the overlay draggable, so it is visible that the box is
  catching clicks rather than passing them through.
- The readme points at the website, since the packaged app carries the Developer ID
  identity that keeps the audio permission across updates.
- Fixed the DMG layout script running a word inside an AppleScript comment: the heredoc
  is unquoted, and the comment held backticks.

## 1.0 · 2026-08-15

First paid release. Live on-device subtitles for macOS system audio: a Core Audio
process tap into a lock-free ring, transcribed by streaming Parakeet/Nemotron on the
Apple Neural Engine through FluidAudio, rendered as a click-through overlay.

What went into it, in the order it happened:

- **The engine.** sherpa-onnx and a streaming Zipformer first, then Parakeet on the
  ANE via CoreML, unusable on CPU at RTF 10.7–31.8 and fine on the Neural Engine. sherpa
  came out again once FluidAudio was the only engine worth keeping. Punctuation and
  capitalisation come from the model rather than a casing pass.
- **Silero VAD**, so music never reaches the recognizer. An energy gate only knows loud
  from quiet, so a backing track was poisoning the encoder's context and losing the
  first words after every musical passage.
- **The overlay.** Pages anchored on audio time rather than word counts, a fade driven
  by text inactivity rather than audio silence, ⇧ to drag, and a position that survives
  the next word arriving.
- **Model switching from the menu bar**, with on-demand download, visible progress, and
  a switch that can cancel the load already running. The picker leads with language and
  is grouped by the download each choice triggers, sized in megabytes rather than
  parameter counts. Multilingual on auto-detect is the default, because a default
  should work before it is configured.
- **Per-app capture** that actually switches, after a leaked tap made "Listen To" look
  flaky rather than broken.
- **A menu bar badge that says something true**, and an audio permission the app tests
  empirically rather than infers: a denial is silent and looks exactly like quiet.
- **Developer ID signing, notarization and a DMG pipeline.** Ad-hoc signing gave every
  build a fresh cdhash, which is how macOS identifies an ad-hoc app, so TCC threw the
  audio grant away on every rebuild.
- **FSL-1.1-ALv2**, replacing 0BSD once the plan was to charge for the binary.
