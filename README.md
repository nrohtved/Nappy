# 😴 Nappy

A small menu bar app for the Mac that puts apps you are not using to sleep, so your Mac works less and uses less power.

> 🚧 **Status:** early alpha (version 0.1.0). It is built for a very recent macOS (the project targets macOS 27.2) and uses the new glass look.

## 🌙 What is Nappy?

Most Mac apps keep doing things in the background even when you are not looking at them: checking for updates, redrawing hidden windows, running timers. Nappy notices the apps you are not using and asks macOS to give them the lowest priority, so they use less of your processor, disk and network. When you come back to an app, it is back to normal right away.

Nappy lives in the menu bar. There is no Dock icon and no main window.

## ⚙️ How it works

- 1️⃣ Nappy checks your running apps every few seconds.
- 2️⃣ An app that has stayed in the background for the time you choose (5 seconds to 1 hour) is put into **macOS background mode**. This is the same kind of throttling that macOS's own App Nap uses: lowest CPU priority, slower disk and network, timers grouped together. The app keeps running, so sound, downloads and sync are not cut off.
- 3️⃣ The app's helper processes (for example the web content processes of a browser) are slowed down together with it.
- 4️⃣ The moment you switch back to the app, press its wake button, or quit Nappy, everything goes back to normal. If Nappy ever quits unexpectedly, it puts everything back the next time it opens.

Some apps are never napped: the app you are using, apps on your ignore list, macOS's own parts (Finder, Dock, and so on), and, if you keep the safety options on, apps that are playing sound, in a call or downloading.

## 🧰 The basics

- 🌙 **Nap Unused Apps** – the main switch, and how long an app must be unused before it naps.
- 😴 **Napping Now** – the apps that are napping, newest first, with how long each has napped. Each row has buttons to wake the app, lock it (see below), or never nap it again.
- 🛡️ **Never Nap These Apps** – your ignore list. Add any open app, or choose one from your Applications folder.
- ⚙️ **Options**
  - *Open Nappy at Login*
  - *Don't Nap Apps You Can See* – apps with a window showing on screen, for example side by side, are left alone.
  - *Don't Nap Busy Apps* – apps playing sound, in a call or downloading keep running normally. The icons of the apps Nappy currently sees as busy are shown under this option.
- 📌 **Pin** (bottom left) – turns the menu into a window that stays open.
- ℹ️ **About** and ☕ **Buy me a coffee** – next to the pin. The coffee button stays hidden while the orange coffee card at the bottom of the menu is showing. Close the card with its ✕ and the button appears in the footer. The card comes back after 3 days.

### 💪 Two stronger tools

- 🔒 **Lock** (the padlock on a napping app): while it naps with no window showing, the app is paused completely, so it cannot wake itself. This saves the most, but see "Good to know". Nappy wakes a locked app when you switch to it, point at one of its windows, point at the Dock, or open Activity Monitor, and before you log out or shut down.
- ⚡ **Electron app helpers**: for apps built with Electron (for example Figma or Notion), the parts that draw the screen are paused in short cycles while the app naps.

## 💡 Good to know

- 🍃 **It is not the real App Nap.** macOS does not let one app switch another app into App Nap, so Nappy uses the closest thing it is allowed to use: background priority. Apps that are truly idle already use almost nothing, so the savings show mostly with apps that do a lot of work in the background.
- 📉 **Savings are modest and vary.** In the author's own tests, the processor work of background apps dropped by roughly a third to a half, and the number of times the processor was woken dropped by about half. Battery savings depend on what you do, and have not been proven by a proper test.
- ⏸️ **Locked apps are paused, not just slowed.** A paused app cannot show notifications, sync, or answer other apps until it is woken. A "Quit" command sent to a paused app by another program does nothing until the app is woken (Force Quit always works). Opening a paused app through Spotlight or a notification has not been fully tested.
- 🐢 **Apps may feel slower for a moment** right after you switch back to them while they catch up.
- 🎮 **Games and video editors:** add them to the ignore list. Napping an app that is busy in the background can make it stutter. Picture in Picture videos in the Dev build are protected by an experimental option; the public build does not have it yet.
- 📦 **Nappy is not sandboxed** because it needs to change other apps' priority. That means it cannot be sold in the Mac App Store, and the early builds are not yet signed for distribution, so macOS may ask you to confirm opening it.
- 💾 Your settings are saved on your Mac. The default ignore list includes Terminal, iTerm2, Xcode, Claude and VS Code if they are installed.

## 🔒 Privacy

🙈 Nappy does not collect anything and does not talk to the internet.

- 🚫 It has no analytics, no accounts and no network code. The only link is the *Buy me a coffee* card and button, which open a web page in your browser when you press them.
- 👀 It looks only at what it needs to decide whether to nap an app: which apps are running, which one is in front, where windows are on screen (position and size, not their contents), and which apps have asked macOS to keep the Mac awake. It does not read your files, your documents or the contents of any window, and it does not take screenshots.
- 🏠 Your settings (delay, ignore list, locked apps) stay on your Mac in the app's preferences. The public build writes no log files. A development build keeps an activity log in `~/Library/Logs/Nappy` for testing.

## ⚖️ Nappy compared with other tools

This is a general comparison of the kinds of tools you might use. It is not a feature-by-feature test of any particular product, so check each tool's own page for the details.

| | Nappy | Tools that quit or hide idle apps (for example Quitter) | CPU limiters (for example App Tamer) | Activity Monitor and macOS itself |
|---|---|---|---|---|
| Idea | Slow down unused apps with macOS's own background mode | Close or hide apps you have not used for a while | Cap how much CPU background apps may use | Show what is using resources; App Nap handles some apps by itself |
| Apps keep running | Yes | No (closed) or hidden | Yes | Yes |
| Nothing is lost when it acts | Yes, nothing is closed or changed in your files | Unsaved work may be at risk if an app is closed | Yes | Yes |
| Automatic | Yes | Yes | Yes | No (manual) |
| Strong "sleep" option | Lock (pauses the app) | Quitting is the strongest | Can pause apps in some tools | Force Quit only |

**✅ Where Nappy is good**
- 🧘 Nothing is closed, so you lose no work and apps come back instantly.
- 🍎 It uses a mechanism that macOS itself provides, so it is gentle and fully reversible.
- 🪶 Simple and small, with no network use.
- 🛟 A safety net: everything is restored when you switch back, quit, log out or shut down, and after a crash.
- 😪 Optional lock for a deeper sleep, with several ways to wake an app quickly.

**⚠️ Where Nappy is weaker**
- 🔧 It cannot make an app use *less work*, only get *less priority*. Tools that quit apps or cap CPU can save more in some cases.
- 🌱 It is an early alpha: fewer settings than mature tools (for example no per-app CPU limits and no schedule), and rough edges, especially around locked apps.
- 🖥️ It needs a very recent macOS, and is not available in the Mac App Store.
- 🔍 The effect is hard to see: the savings are real but modest, and a locked app can behave oddly because it is paused.

## ☕ Support

If Nappy is useful to you, you can [buy me a coffee ☕](https://buymeacoffee.com/nrohtved).
