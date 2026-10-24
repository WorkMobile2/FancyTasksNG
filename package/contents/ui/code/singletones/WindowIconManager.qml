/*
    SPDX-FileCopyrightText: 2026 Vitaliy Elin <daydve@smbit.pro>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

pragma Singleton
import QtQuick
import QtCore
import org.kde.plasma.plasma5support as Plasma5Support

/**
 * WindowIconManager — EXPERIMENTAL. Resolves per-window X11 icons through
 * ~/.local/bin/remote-tasks-x11 and caches them by window id.
 *
 * Reading (`icons`) is side-effect free. Helper execution happens only in
 * request(), which callers must invoke explicitly (never from a binding).
 */
Item {
    id: root

    // wid (string) -> icon URL. Replaced (not mutated) so bindings re-evaluate.
    property var icons: ({})

    readonly property int retryBackoffMs: 60000

    property var _inFlight: ({})
    property var _failedAt: ({})
    property var _pendingIcons: ({})
    property var _moveCommands: ({})
    property Item validationHost: null

    function moveToMonitor(wids, direction) {
        if (direction !== "next" && direction !== "previous") return;
        for (let i = 0; wids && i < wids.length; ++i) {
            const key = _normalizeWid(wids[i]);
            if (!key || !_helperPath) continue;
            const cmd = _shellQuote(_helperPath) + " move-monitor " + key + " " + direction;
            if (_moveCommands[cmd]) continue;
            _moveCommands[cmd] = true;
            executor.connectSource(cmd);
        }
    }

    readonly property string _helperPath: {
        const home = decodeURIComponent(String(StandardPaths.writableLocation(StandardPaths.HomeLocation)))
            .replace(/^file:\/\//, "").replace(/\/+$/, "");
        return home ? home + "/.local/bin/remote-tasks-x11" : "";
    }

    function _normalizeWid(wid) {
        const s = String(wid);
        return /^[0-9]+$/.test(s) && Number(s) > 0 ? s : "";
    }

    function _shellQuote(s) {
        return "'" + s.replace(/'/g, "'\\''") + "'";
    }

    // Starts an asynchronous lookup unless cached, in flight or backing off.
    function request(wid, host) {
        // Canvas needs a window; the singleton itself is not in the scene.
        if (!validationHost && host) validationHost = host;
        const key = _normalizeWid(wid);
        if (!key || !_helperPath) return;
        if (key in icons || key in _inFlight) return;
        for (const url in _pendingIcons) {
            if (_pendingIcons[url] === key) return;
        }
        const failed = _failedAt[key];
        if (failed !== undefined && Date.now() - failed < retryBackoffMs) return;

        // Helper must print a path to an existing, non-empty file.
        const cmd = "p=$(" + _shellQuote(_helperPath) + " icon " + key + ") && [ -s \"$p\" ] && printf '%s\\n' \"$p\"";
        _inFlight[key] = cmd;
        executor.connectSource(cmd);
    }

    function _finish(source, data) {
        let key = "";
        for (const k in _inFlight) {
            if (_inFlight[k] === source) { key = k; break; }
        }
        // Not ours, or a repeated update for an already handled request.
        if (!key) return;

        delete _inFlight[key];
        executor.disconnectSource(source);

        const out = String(data["stdout"] || "").trim();
        if (data["exit code"] === 0 && out.charAt(0) === "/" && out.indexOf("\n") < 0) {
            const url = "file://" + encodeURIComponent(out).replace(/%2F/g, "/");
            _pendingIcons[url] = key;
            iconValidator.loadImage(url);
            iconValidator.requestPaint();
        } else {
            _failedAt[key] = Date.now();
        }
    }

    // A valid PNG may contain no visible pixels (notably during PWA startup).
    // Sample asynchronously before publishing it; keep the model icon otherwise.
    Canvas {
        id: iconValidator
        parent: root.validationHost
        width: 32
        height: 32
        opacity: 0
        onImageLoaded: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            for (const url in root._pendingIcons) {
                const key = root._pendingIcons[url];
                if (isImageError(url)) {
                    root._failedAt[key] = Date.now();
                } else if (isImageLoaded(url)) {
                    ctx.clearRect(0, 0, width, height);
                    ctx.drawImage(url, 0, 0, width, height);
                    const pixels = ctx.getImageData(0, 0, width, height).data;
                    let visiblePixels = false;
                    for (let i = 3; i < pixels.length; i += 4) {
                        if (pixels[i] > 0) { visiblePixels = true; break; }
                    }
                    if (visiblePixels) {
                        const copy = Object.assign({}, root.icons);
                        copy[key] = url;
                        root.icons = copy;
                    } else {
                        root._failedAt[key] = Date.now();
                    }
                } else {
                    continue;
                }
                delete root._pendingIcons[url];
                unloadImage(url);
            }
        }
    }

    Plasma5Support.DataSource {
        id: executor
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            if (data["exit code"] === undefined) return; // still running
            if (root._moveCommands[sourceName]) {
                delete root._moveCommands[sourceName];
                executor.disconnectSource(sourceName);
                if (data["exit code"] !== 0)
                    console.warn("FancyTasksNG monitor move failed: " + String(data["stderr"] || ""));
                return;
            }
            root._finish(sourceName, data);
        }
    }
}
