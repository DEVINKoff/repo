# DevTest 2.0: Liquid Glass, Widgets, Dynamic Island

Test app for sideloading. It's built in the cloud on a GitHub Actions Mac runner, so you don't need a Mac.

## Build (from Windows)
1. Create a GitHub repo (it can be private) and upload this whole folder, including `.github/`.
2. The **Build unsigned IPA** workflow starts on push. You can also run it from the Actions tab with "Run workflow".
3. When it finishes, download the **DevTest-ipa** artifact from the run page and unzip it to get `DevTest.ipa`.

## Install
Sign and install with Sideloadly. Keep the app extensions; don't tick "remove extensions". The widget is its own extension, so a free Apple ID uses 2 of its 10 weekly App IDs.

## What to test
- **Liquid Glass** (iOS 26+): glass cards and buttons, morphing glass blobs, and regular/clear/tinted samples. An in-app toggle compares glass with the old blur look.
- **Widgets**: "DevTest Tapper" comes in small, medium and Lock Screen sizes. The +1 and Reset buttons work right on the widget.
- **Dynamic Island**: Start, +1 and End a Live Activity from the app. Long-press the island for +1/End buttons. It also shows on the Lock Screen.

Minimum iOS is 17. Below iOS 26 the app falls back to blur material.
