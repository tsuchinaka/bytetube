/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The developer's view into what the player is doing.
 *
 * Turned on with the "Log playback details" switch in Preferences, or with
 * the BYTETUBE_DEBUG environment variable for a single run. Everything goes
 * to standard output, one line per phase, so following a video from request
 * to first frame is a matter of reading down.
 */

namespace ByteTube {

public class Debug : GLib.Object {
    private static GLib.Settings? settings = null;

    public static bool enabled () {
        if (GLib.Environment.get_variable ("BYTETUBE_DEBUG") != null) {
            return true;
        }

        if (settings == null) {
            settings = new GLib.Settings (Config.APP_ID);
        }

        return settings.get_boolean ("debug-logging");
    }

    /** Callers format the message themselves with printf. */
    public static void log (string message) {
        if (!enabled ()) {
            return;
        }

        stdout.printf ("[bytetube] %s\n", message);
        stdout.flush ();
    }
}
}
