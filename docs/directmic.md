# DirectMic setup

BotSpeaker 0.5.7 includes a signed universal DirectMic driver inside the Mac application. Installation needs no source repository, compiler, or separate download. It works on Apple Silicon and Intel Macs running macOS 14 or later.

1. Copy BotSpeaker from the DMG into Applications and open it.
2. Open an orchestrated script and choose **Host in Recall.ai**.
3. Enable **Include this computer as speaker 1**, then **Send host speech directly to DirectMic**.
4. End active calls and recordings. Choose **Install DirectMic…**, confirm the audio interruption, and authorize the standard macOS administrator prompt.
5. Select **DirectMic** as the microphone in your meeting app. Reopen the meeting app if needed; **Refresh status** refreshes BotSpeaker’s detection.
6. Prepare and start the scripted meeting as usual. Host speech goes directly to the microphone input without playing through an output device.

DirectMic is optional and is used only by the explicit Recall host routing option. It does not replace the microphone selection in other apps automatically. Installation or reinstallation restarts the system audio service, briefly interrupting all audio. It installs `/Library/Audio/Plug-Ins/HAL/DirectMic.driver`; no daemon or login item is installed.

To uninstall, end calls, select another microphone, remove `/Library/Audio/Plug-Ins/HAL/DirectMic.driver` using Finder with administrator authorization, then restart the Mac. Do not remove other audio plug-ins.

## Release builds

The release machine needs the private DirectMic source checkout with its pinned libASPL dependency. Set `DIRECTMIC_SOURCE_DIR` to that checkout, or place it next to BotSpeaker as `../DirectMic`. `scripts/release-macos.sh` builds both architectures, signs the driver, bundles its dependency licenses, embeds it in the app, and re-signs the app before DMG notarization. End users never need access to the private checkout. Development Xcode builds without the bundled driver disable the install action.

For a release that leaves DirectMic unchanged, `DIRECTMIC_INSTALLER_APP` can point to the bundled installer from a prior BotSpeaker release. Packaging verifies the installer and driver signatures, their signing team and bundle identities, and both architectures before copying the component. `BOTSPEAKER_EXPORT_OPTIONS_PLIST` can select machine-specific export options for an installed Developer ID provisioning profile.

DirectMic uses libASPL under the MIT license; its license and included Apple notices are inside the driver’s `Contents/Resources` folder. One local producer should feed DirectMic at a time.
