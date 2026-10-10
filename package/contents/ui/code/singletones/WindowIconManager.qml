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
    function request(wid) {
        const key = _normalizeWid(wid);
        if (!key || !_helperPath) return;
        if (key in icons || key in _inFlight) return;
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
            const copy = Object.assign({}, icons);
            copy[key] = "file://" + encodeURI(out);
            icons = copy;
        } else {
            _failedAt[key] = Date.now();
        }
    }

    Plasma5Support.DataSource {
        id: executor
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            if (data["exit code"] === undefined) return; // still running
            root._finish(sourceName, data);
        }
    }
}
