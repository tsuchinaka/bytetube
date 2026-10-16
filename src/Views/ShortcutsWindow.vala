/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Every keyboard shortcut the app has, in one place.
 *
 * GTK's own shortcuts window is deprecated, so this is a plain transient
 * window listing the accelerators that the app and the window registered.
 */

public class ByteTube.ShortcutsWindow : Gtk.Window {
    public ShortcutsWindow () {
        Object (
            title: _("Keyboard Shortcuts"),
            resizable: false,
            default_width: 380
        );
    }

    construct {
        var header_bar = new Gtk.HeaderBar () {
            show_title_buttons = true,
            title_widget = new Gtk.Label ("")
        };
        titlebar = header_bar;

        var list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE
        };
        list.add_css_class (Granite.CssClass.CARD);

        list.append (build_row (_("Search Videos"), "<Control>f"));
        list.append (build_row (_("Reload Results"), "<Control>r"));
        list.append (build_row (_("Go Back"), "<Alt>Left"));
        list.append (build_row (_("Go Forward"), "<Alt>Right"));
        list.append (build_row (_("Go to Discover"), "<Alt>Home"));
        list.append (build_row (_("Toggle Sidebar"), "F9"));
        list.append (build_row (_("Play or Pause"), "space"));
        list.append (build_row (_("Seek Back 10 Seconds"), "Left"));
        list.append (build_row (_("Seek Forwards 10 Seconds"), "Right"));
        list.append (build_row (_("Mute or Unmute"), "m"));
        list.append (build_row (_("Zoom to Fill or Fit"), "z"));
        list.append (build_row (_("Leave Fullscreen"), "Escape"));
        list.append (build_row (_("Toggle Fullscreen"), "F11"));
        list.append (build_row (_("Open Preferences"), "<Control>comma"));
        list.append (build_row (_("Quit"), "<Control>q"));

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        box.append (list);

        child = box;
    }

    private static Gtk.ListBoxRow build_row (string label, string accel) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 9,
            margin_end = 9
        };

        box.append (new Gtk.Label (label) {
            xalign = 0,
            halign = Gtk.Align.FILL,
            hexpand = true
        });

        box.append (new Granite.AccelLabel ("", accel) {
            halign = Gtk.Align.END
        });

        return new Gtk.ListBoxRow () {
            child = box,
            activatable = false,
            selectable = false
        };
    }
}
