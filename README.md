# UAI: Universal AI for Mac

One Slack-style Mac app for all your AIs: **Claude, ChatGPT, Gemini, DeepSeek, Muse (Meta AI) and Grok (xAI)**, plus **Universal AI**, which sends each prompt to the AI best suited for it.

```
┌────┬──────────────────────────────────────────────────────────────┐
│ ✦  │  ‹ ›          [ 🔍 Search all AIs                ]   🖼 Media │
│────│──────────────────────────────────────────────────────────────│
│ C  │                                                              │
│ G  │        The selected AI, signed in with YOUR account          │
│ G  │        (chats sync with its phone/web/desktop apps)          │
│ D  │                                                              │
│ M  │                                                              │
│ X  │                                                              │
│ ⚙  │                                                              │
└────┴──────────────────────────────────────────────────────────────┘
```

## Features

| | |
|---|---|
| **Left rail** | One icon per AI, Slack workspace style. ⌘1 is Universal AI and ⌘2–⌘7 are the AIs. |
| **Your own logins** | Each AI is its official web app running inside UAI. Sign in once with your own account. Your chats, history, subscriptions and settings are the same ones you see on the official apps, synced both ways. |
| **Universal AI** | Type once and UAI picks the AI: images go to ChatGPT, video to Gemini, news/X to Grok, code and writing to Claude, math to DeepSeek, Meta apps to Muse. It opens a new chat there under your account and sends the prompt. You can override the pick per message. Add an Anthropic API key in Settings to let Claude make the call instead of the built-in rules. |
| **Back / Forward** | ‹ › (⌘[ / ⌘]) go back within the current AI first, then through the AIs you visited. |
| **Search all AIs** | ⌘K searches chats from every AI account at once, plus Universal AI prompts and Media files. UAI indexes chat titles from each AI's sidebar, and the text of chats you open, so results grow as you use it. |
| **Media** | Anything you download from any AI (images, videos, PDFs, reports) is saved to `~/Documents/UAI Media/<AI>/` and shown in a gallery you can filter by type and by AI. |

## Install on your iMac

1. Open the **Actions** tab of this repo, open the latest green **Build UAI** run, and download **UAI-macOS** (or grab `UAI.zip` from a Release).
2. Unzip it and drag **UAI.app** into **Applications**.
3. The app isn't notarized by Apple, so on first launch macOS will block it. Either:
   - open **System Settings → Privacy & Security** and click **Open Anyway**, or
   - run `xattr -dr com.apple.quarantine /Applications/UAI.app` in Terminal.
4. Click each AI in the left rail once and sign in.

Requires macOS 14 Sonoma or newer. The build is universal, so it runs on both Apple Silicon and Intel iMacs.

## Build it yourself

```bash
./scripts/build-app.sh      # needs Xcode 16+ command line tools
open build/UAI.app
```

To publish a release, push a tag such as `v0.1.0`. CI builds the app and attaches `UAI.zip` to a GitHub Release.

## Notes and limits

- **Muse** points to Meta AI (`meta.ai`). You can change any AI's address in **Settings → AI Services**.
- **xAI and Grok** are one entry: Grok is xAI's assistant.
- Universal AI and search work by reading and typing into each AI's own web page. If a provider redesigns its site, auto-send can stop working. UAI then copies your prompt so you can paste it with ⌘V, and you can turn auto-send off in Settings.
- Search covers chats UAI has seen: the ones listed in each AI's sidebar while it was open in UAI, and the full text of chats you opened in UAI.
- Nothing leaves your Mac except the AIs' own traffic. The only exception is the optional Claude routing call, which sends the prompt to the Anthropic API with your key. The key is stored in the macOS Keychain.

## Project layout

```
Sources/UAI/
  UAIApp.swift              app entry, menus and shortcuts
  Models/Provider.swift     the AIs, their URLs and strengths
  Stores/WebViewStore.swift web views, sign-in popups, downloads, chat indexing, prompt delivery
  Stores/…                  navigation, search index, media library, Universal history
  Router/Router.swift       rules + optional Claude-based routing
  Views/…                   rail, top bar, Universal AI, Media, search, settings
scripts/build-app.sh        builds and signs UAI.app
.github/workflows/build.yml builds on a macOS runner on every push
```
