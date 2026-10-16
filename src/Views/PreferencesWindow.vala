/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The two things the app cannot work out for itself.
 *
 * Everything else follows the operating system or is remembered
 * automatically; the HIG asks apps not to expose settings they do not need.
 */

public class ByteTube.PreferencesWindow : Gtk.Window {
    private GLib.Settings settings;

    public PreferencesWindow (Gtk.Window parent) {
        Object (
            title: _("Preferences"),
            transient_for: parent,
            modal: false,
            resizable: false,
            default_width: 420
        );
    }

    construct {
        settings = new GLib.Settings (Config.APP_ID);

        var header_bar = new Gtk.HeaderBar () {
            show_title_buttons = true,
            title_widget = new Gtk.Label ("")
        };
        titlebar = header_bar;

        var list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE
        };
        list.add_css_class (Granite.CssClass.CARD);

        var autoplay = new Gtk.Switch () { valign = Gtk.Align.CENTER };
        settings.bind ("autoplay", autoplay, "active", SettingsBindFlags.DEFAULT);
        list.append (build_row (
            _("Autoplay videos"),
            _("Start playing as soon as a video opens"),
            autoplay
        ));

        var debug_logging = new Gtk.Switch () { valign = Gtk.Align.CENTER };
        settings.bind ("debug-logging", debug_logging, "active", SettingsBindFlags.DEFAULT);
        list.append (build_row (
            _("Log playback details"),
            _("Write what the player is doing to the log for troubleshooting"),
            debug_logging
        ));

        var history = new Gtk.Switch () { valign = Gtk.Align.CENTER };
        settings.bind ("save-watch-history", history, "active", SettingsBindFlags.DEFAULT);
        list.append (build_row (
            _("Remember watched videos"),
            _("Keep a list of the videos you have opened"),
            history
        ));

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        box.append (list);

        child = box;
    }

    private static Gtk.ListBoxRow build_row (string title, string description, Gtk.Switch control) {
        var text = new Gtk.Box (Gtk.Orientation.VERTICAL, 3) {
            hexpand = true
        };
        text.append (new Gtk.Label (title) {
            xalign = 0,
            halign = Gtk.Align.FILL
        });

        var detail = new Gtk.Label (description) {
            xalign = 0,
            wrap = true,
            halign = Gtk.Align.FILL
        };
        detail.add_css_class (Granite.CssClass.DIM);
        detail.add_css_class (Granite.CssClass.SMALL);
        text.append (detail);

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 9,
            margin_end = 9
        };
        box.append (text);
        box.append (control);

        return new Gtk.ListBoxRow () {
            child = box,
            activatable = false
        };
    }
}
