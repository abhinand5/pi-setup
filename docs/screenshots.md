# Screenshots on this machine

Desktop session is KDE on Wayland (`WAYLAND_DISPLAY=wayland-0`), with an X11 display
(`:1`) kept for compatibility. That combination breaks the obvious tool:

```text
$ import -window root /tmp/shot.png
import-im6.q16: unable to read X window image `root': Resource temporarily unavailable
```

`import` (ImageMagick) needs an X11 root window, and under KDE/Wayland there is none to
read, so the command fails with the error above rather than producing an image.

## Working command

```bash
spectacle -b -n -a -o /tmp/shot.png     # -a = active window, -b background, -n no notification
```

**Pass the capture mode every time.** Spectacle's default is `-f`, the *entire desktop*, so
`-o file` alone reproduces the incident this page exists for: on 2026-11-19 a full-screen
grab of a tmux test window brought an unrelated `pi` session (8 windows, work in progress on
another project) into the agent's context. `-a` captures only the active window — verified
here, 2014x1330 for a kitty window rather than the desktop.

| Mode | Flag | Use |
| --- | --- | --- |
| active window | `-a` | the default choice: the window under test, nothing else |
| region | `-r` | rectangle; opens a selection overlay, so it needs a human |
| current monitor | `-m` | one display of a multi-head setup |
| entire desktop | `-f` | only when the whole desktop IS the subject; this is the default, hence easy to get by accident |

## Reading the image

The `read` tool accepts a PNG path and returns it as an attachment. That costs context in
proportion to the image, so capture one window at a time and only when the answer is visual
(a gradient that separates truecolor from 256 colours, a layout, a rendered state). For
anything textual, `tmux capture-pane -p`, `grep`, or a log line is cheaper and exact.

## Browser screenshots

A web page goes through the Playwright MCP server instead — the `browser-uat` skill and
`~/.pi/agent/skills/browser-uat/scripts/uat.sh` — because Playwright captures its own page
and none of the Wayland caveats above apply. Use this page for native windows (kitty, tmux,
a desktop app); use `browser-uat` for anything rendered in a browser.
