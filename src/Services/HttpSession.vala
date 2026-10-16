/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The one HTTP session the whole app shares.
 *
 * Every request the app makes goes to the same service, so sharing a session
 * lets connections be reused instead of re-established for every video, every
 * search and every thumbnail. On a warm connection that is the difference
 * between a request that just asks and one that introduces itself first.
 */

public class ByteTube.HttpSession : GLib.Object {
    private static Soup.Session? shared = null;

    public static Soup.Session get_shared () {
        if (shared == null) {
            shared = new Soup.Session () {
                timeout = 30,
                idle_timeout = 120
            };
        }

        return shared;
    }
}
