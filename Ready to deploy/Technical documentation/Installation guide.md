# QA Engine – Installation guide

The **engine** is the always-on part of the QA platform. It takes queued audits from the cloud database and judges
them with an AI model through a team of Neuro SAN agents. At least one manager's computer must have it running at any
time (the website works without it, but audits wait in the queue until an engine is on).

You need about 30–40 minutes the first time (most of it is waiting for downloads).

---

## Part 1. Before you start

Check each item.

| # | You need | How to check |
|---|---|---|
| 1 | Windows 10 or 11, signed in with your own user | – |
| 2 | **Google Chrome** installed | Start menu → Chrome opens |
| 3 | Internet access (the installer downloads the Python packages) | – |
| 4 | About 6 GB free on drive C: (the on-device AI model is about 2 GB) | File Explorer → This PC |
| 5 | The **Ready to deploy** folder with these files: `Install.cmd`, `install.ps1`, `launcher-common.ps1`, `QA-Engine-….zip`, `QA-Engine-….zip.sha256`, `env.template`, `Installation-and-Documentation.html` (this guide and all the technical documents, open it in any browser), and the `Technical documentation` folder | Open the folder |
| 6 | The **.env settings file**, sent to you privately by the developer. It is not in the folder | Saved on your Desktop |

Python 3.12 or newer is also needed. If it is missing the installer tries to install it for you.

> Never forward the `.env` file, post it in a chat, or save it in a shared folder. It contains the passwords.

---

## Part 2. Install (once)

1. Copy the whole **Ready to deploy** folder to the computer (for example to your Desktop). Keep the files together.
2. Double-click **`Install.cmd`**. If Windows shows "Windows protected your PC", choose *More info*, then *Run anyway*.
3. A black window opens and shows six steps. Wait for each `[ OK ]`:
   - **1/6** checks that the package is not damaged.
   - **2/6** opens a file window: choose the **.env** file you received, then click *Open*.
     The installer checks that every required setting is in it.
   - **3/6** checks Python and Chrome.
   - **4/6** copies the engine to `C:\QAEngine`.
   - **5/6** stores your settings **encrypted for your Windows user** and installs the Python packages (the longest step:
     several minutes).
   - **6/6** creates four shortcuts on the Desktop (Start, Stop, Status, Show logs) and runs a self-test.
4. At the end you should read **Installation finished**. If you read `[FAIL]`, see Part 8.
5. **Delete the `.env` file** you were sent (also from the Recycle Bin). The engine keeps its own encrypted copy.

You now have four Desktop shortcuts: **QA Engine – Start**, **QA Engine – Status**, **QA Engine – Stop** and **QA Engine – Show logs**.

---

## Part 3. First start

1. Double-click **QA Engine – Start**.
2. A window opens showing the steps. Also a separate Chrome window opens: that is the engine's own Chrome, leave it
   open (you can minimise it). Do not use it for browsing.
3. Wait until you read *The engine is running*. Your browser then opens **Studio** (`http://127.0.0.1:4173`), the page that shows the agent networks working; the raw list at `http://127.0.0.1:8080/api/v1/list` is only for technical checks. The first start can take several minutes while the AI model loads.
4. Double-click **QA Engine – Status**. Everything should be green:
   - Supervisor, Chrome, Bridge, Neuro SAN server and Studio running
   - "Gemini Nano model is loaded"
   - File watcher and Audit worker running
5. Leave the Start window open (or minimised).

> If you cannot see "Gemini Nano model is loaded" after 10 minutes, do Part 4.

---

## Part 4. Download the AI model (only if Status says the model is not loaded)

This applies to the **on-device** mode (`AI_PROVIDER=nano`). It is not needed in cloud mode (Part 7).

1. In the engine's own Chrome window, open this address: `http://127.0.0.1:8000/`
2. Press **F12**, click the **Console** tab.
3. Copy the whole block below, paste it into the console and press **Enter**. (Chrome may ask you to type
   `allow pasting` first: type it and press Enter, then paste again.)

```js
(async () => {
  if (!('LanguageModel' in self)) { console.log('LanguageModel API missing: start Chrome through the engine (QA Engine - Start) and use Chrome 138 or newer'); return; }
  console.log('Availability before:', await LanguageModel.availability());
  const session = await LanguageModel.create({
    monitor(m) { m.addEventListener('downloadprogress', e => console.log('Downloading Gemini Nano: ' + Math.round(e.loaded * 100) + '%')); }
  });
  console.log('Test answer:', await session.prompt('Reply with the single word OK.'));
  session.destroy();
  console.log('Availability after:', await LanguageModel.availability(), '-> Nano is ready');
})();
```

4. Wait until the console prints **Nano is ready**. The progress is printed as a percentage. If it does not start,
   click once inside the page and run the block again.
5. Run **QA Engine – Status** again.

---

## Part 5. Every day

| Do this | When |
|---|---|
| **QA Engine – Status** | At the start and end of your shift: all green |
| **QA Engine – Start** | If it is not running |
| **QA Engine – Stop** | Only when you hand over and the next manager's engine is already running, or for maintenance |
| **QA Engine – Show logs** | Opens one live window per log (worker, **agents**, bridge, Neuro SAN) and tiles them on the screen. The **AGENTS** window shows, line by line, which agent asks which tool or agent for what, and what comes back. For demos and for checking what the engine is doing. It only reads the logs: closing the windows does not stop the engine |

Rules while the engine runs:
- Do not close the Start window or the engine's Chrome window.
- Do not shut down, sleep or log out. Lock the screen instead (Windows key + L). The engine asks Windows to stay awake.
- Keep the laptop plugged in.
- Logs are in `C:\QAEngine\data\logs` (`worker.log`, `bridge.log`, `neurosan.log`). Send them to the developer if there is a problem.

**Handover between shifts:** the next manager starts their engine first, checks Status, and then the previous one
stops theirs. Two engines can run at once.

---

## Part 6. Test that it works

1. Open the website and log in.
2. Choose **New audit**, upload a sample call and press **Save and queue audit**.
3. On the engine computer open `C:\QAEngine\data\logs\worker.log`. You should see `Claimed audit job …`.
4. After a few minutes the result appears on the website.

---

## Part 7. Use the cloud AI instead of the on-device AI

When the company provides a **Gemini API key**, the engine can use the cloud model. It is faster and more reliable.
It needs **no Chrome and no bridge**.

> Data note: in cloud mode the (masked) call text is sent to Google. Only switch with the approval of the data
> protection owner.

**Where the key goes:** in the `.env` file, in these lines:

```
AI_PROVIDER=gemini
GOOGLE_API_KEY=<paste the key here, no quotes, no spaces>
GEMINI_MODEL=gemini-2.5-flash
```

Steps:
1. Get the current `.env` from the developer (or open your copy of `env.template`, fill it and save as `.env`) and change
   those three lines.
2. Double-click `C:\QAEngine\launcher\Update-secrets.cmd` and choose that `.env`. It replaces the stored settings.
   If the key is missing it tells you and changes nothing.
3. Run **QA Engine – Stop**, then **QA Engine – Start**. The start window now says `(AI: gemini)` and does not open Chrome.
4. Run **QA Engine – Status**: it shows "Cloud Gemini in use". Delete the `.env` you used.

To go back to the on-device AI, set `AI_PROVIDER=nano`, run Update-secrets again and restart.

Start rewrites the model setting of every agent network automatically (the file `switch_llm.py` does it), so you never
edit the agent files by hand.

---

## Part 8. If something goes wrong

| Symptom | What to do |
|---|---|
| Installer: "checksum mismatch" | The package is damaged. Ask for a new copy of the folder |
| Installer: ".env file is incomplete. Missing: …" | Ask the developer for a complete `.env` |
| Installer: "Python 3.12+ is required" | Install Python from python.org, tick **Add python.exe to PATH**, run `Install.cmd` again |
| Installer: "Installing the requirements failed" | Check the internet connection and run `Install.cmd` again (it is safe to repeat) |
| Start: "Google Chrome was not found" | Install Chrome (on-device mode only) |
| Start: "AI_PROVIDER must be nano or gemini" | Fix the `.env` (Part 7) |
| Status: model not loaded after 10 minutes | Part 4 |
| Status: something red | Run Stop, then Start. If it stays red, send `C:\QAEngine\data\logs` to the developer |
| Audits stay "queued" on the website | The engine is off, or Status shows a red item |
| Audits show "failed" | Send the error text from the audit to the developer |
| Passwords were changed | Get the new `.env` and run `C:\QAEngine\launcher\Update-secrets.cmd` |

---

## Part 9. Update to a new version

The developer sends a new **Ready to deploy** folder (with a newer `QA-Engine-….zip`).
1. Replace your old folder with the new one.
2. Double-click `Install.cmd`. It stops the old engine, installs the new version next to the old one, and **keeps your
   saved settings** (no `.env` needed again).
3. Start the engine with the Desktop shortcut and check Status.

If the update needs a new `.env` (for example for cloud mode), the developer tells you; then use Update-secrets.

---

## Part 10. Uninstall

1. Run **QA Engine – Stop**.
2. Delete the folders `C:\QAEngine` and `C:\ChromeNanoSession`.
3. Delete the four **QA Engine** shortcuts on the Desktop.

---

## For the developer: preparing the package

1. Run `supabase\platform_setup.sql` in the Supabase SQL Editor (needed once, and again if the file changes).
2. Build: `powershell -ExecutionPolicy Bypass -File .\packaging\build_package.ps1 -Version 1.2.0`
   This creates the **Ready to deploy** folder next to the project. The build stops if it finds a `.env` or anything that
   looks like a key inside the package.
3. Send the folder to the managers by your usual file channel, and the **.env** separately and privately.
4. Create the `.env` from `packaging\env.template`. Use the restricted `qa_worker` database role in `DATABASE_URL`, never the
   admin one. Rotate the ingest and `qa_worker` passwords before the first distribution.
