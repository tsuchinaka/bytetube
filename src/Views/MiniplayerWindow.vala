/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The video in a small window of its own.
 *
 * Opening it reparents the watch page's player here; closing it sends the
 * player back. The pipeline itself is never touched, so playback continues
 * across both moves without restarting. Only one can exist: opening another
 * one closes the one that is already open.
 */

public class ByteTube.MiniplayerWindow : Gtk.Window {
    private static MiniplayerWindow? open_window = null;

    /** The box the player is handed to. Empty unless this window holds it. */
    public Gtk.Box holder { get; private set; }

    public MiniplayerWindow () {
        Object (
            title: _("Miniplayer"),
            default_width: 400,
            default_height: 260
        );
    }

    construct {
        holder = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true
        };

        child = holder;

        // The watch page reparents the player back before the window goes
        // away; forgetting the reference here keeps a closed window from
        // being handed out again.
        close_request.connect (() => {
            if (open_window == this) {
                open_window = null;
            }

            return false;
        });
    }

    /** Closes the open miniplayer, if there is one. */
    public static void close_any () {
        if (open_window != null) {
            open_window.close ();
        }
    }

    public static new MiniplayerWindow get () {
        if (open_window == null) {
            open_window = new MiniplayerWindow ();
        }

        return open_window;
    }
}
