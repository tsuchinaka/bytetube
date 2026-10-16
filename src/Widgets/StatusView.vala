/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A compact empty, error, or loading state.
 *
 * Every view that loads something from the network can end up with nothing to
 * show. Rather than leaving a blank page, each of those cases says what
 * happened and, where there is something to do about it, offers the action.
 */

public class ByteTube.StatusView : Gtk.Box {
    public signal void action_requested ();

    private Gtk.Spinner spinner;

    public StatusView () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 18,
            halign: Gtk.Align.CENTER,
            valign: Gtk.Align.CENTER,
            hexpand: true,
            vexpand: true
        );
    }

    construct {
        spinner = new Gtk.Spinner () {
            width_request = 32,
            height_request = 32
        };
    }

    public void show_loading () {
        clear_children ();

        spinner.start ();
        append (spinner);
    }

    /**
     * @param action_label Label for the button that retries or moves on. When
     *        empty, the state is purely informational.
     */
    public void show_message (
        string title,
        string description,
        string icon_name,
        string? action_label = null,
        string action_icon = "view-refresh-symbolic"
    ) {
        clear_children ();

        var placeholder = new Granite.Placeholder (title) {
            description = description,
            icon = new GLib.ThemedIcon (icon_name)
        };

        if (action_label != null && action_label != "") {
            var button = placeholder.append_button (
                new GLib.ThemedIcon (action_icon),
                action_label,
                ""
            );
            button.clicked.connect (() => action_requested ());
        }

        append (placeholder);
    }

    private void clear_children () {
        spinner.stop ();

        var child = get_first_child ();
        while (child != null) {
            remove (child);
            child = get_first_child ();
        }
    }
}
