/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 */

public class ByteTube.Application : Gtk.Application {
    public const string ACTION_QUIT = "quit";
    public const string ACTION_ABOUT = "about";
    public const string ACTION_SHORTCUTS = "shortcuts";

    private MainWindow? main_window = null;
    private bool color_scheme_followed = false;

    public Application () {
        Object (
            application_id: Config.APP_ID,
            flags: ApplicationFlags.HANDLES_OPEN
        );
    }

    protected override void startup () {
        base.startup ();

        Granite.init ();
        load_stylesheet ();

        register_actions ();
    }

    protected override void activate () {
        follow_system_color_scheme ();
        present_window ();
    }

    protected override void open (File[] files, string hint) {
        follow_system_color_scheme ();

        foreach (var file in files) {
            var video_id = Video.id_from_uri (file.get_uri ());
            if (video_id != null) {
                present_window ().open_video_id (video_id);
                return;
            }
        }

        present_window ();
    }

    // ------------------------------------------------------------------

    private MainWindow present_window () {
        if (main_window == null) {
            main_window = new MainWindow (this);
        }

        main_window.present ();
        return main_window;
    }

    /**
     * The stylesheet is added through the C entry point rather than through
     * GTK's Vala binding, whose wrapper for it sits on a type that is itself
     * deprecated.
     */
    [CCode (cname = "gtk_style_context_add_provider_for_display")]
    private extern static void add_provider_for_display (
        Gdk.Display display,
        Gtk.StyleProvider provider,
        uint priority
    );

    private void load_stylesheet () {
        var provider = new Gtk.CssProvider ();
        provider.load_from_resource (Config.RESOURCE_PREFIX + "/style.css");

        add_provider_for_display (
            Gdk.Display.get_default (),
            provider,
            (uint) Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private void follow_system_color_scheme () {
        if (color_scheme_followed) {
            return;
        }

        color_scheme_followed = true;

        var granite_settings = Granite.Settings.get_default ();
        var style_manager = Granite.StyleManager.get_default ();

        style_manager.color_scheme = granite_settings.prefers_color_scheme;

        granite_settings.notify["prefers-color-scheme"].connect (() => {
            style_manager.color_scheme = granite_settings.prefers_color_scheme;
        });
    }

    private void register_actions () {
        var quit_action = new SimpleAction (ACTION_QUIT, null);
        quit_action.activate.connect (() => quit ());
        add_action (quit_action);
        set_accels_for_action ("app." + ACTION_QUIT, { "<Control>q" });

        var about_action = new SimpleAction (ACTION_ABOUT, null);
        about_action.activate.connect (() => show_about ());
        add_action (about_action);

        var shortcuts_action = new SimpleAction (ACTION_SHORTCUTS, null);
        shortcuts_action.activate.connect (() => show_shortcuts ());
        add_action (shortcuts_action);
        set_accels_for_action ("app." + ACTION_SHORTCUTS, { "<Control>question", "<Control>F1" });
    }

    private void show_about () {
        string[] authors = { "ByteTube Developers" };

        var about = new Gtk.AboutDialog () {
            program_name = _("ByteTube"),
            version = "1.0.0",
            comments = _("Browse and watch online videos"),
            logo_icon_name = Config.APP_ID,
            license_type = Gtk.License.GPL_3_0,
            website = "https://github.com/bytetube/bytetube",
            website_label = _("ByteTube Website"),
            copyright = "Copyright © 2026 ByteTube Developers"
        };

        about.add_credit_section (_("Made by"), authors);

        if (main_window != null) {
            about.transient_for = main_window;
            about.modal = true;
        }

        about.present ();
    }

    private void show_shortcuts () {
        var shortcuts = new ShortcutsWindow ();
        if (main_window != null) {
            shortcuts.transient_for = main_window;
        }

        shortcuts.present ();
    }

    public static int main (string[] args) {
        // The playback pipeline is built with GStreamer, which has to be
        // initialised before any of its elements can be created.
        Gst.init (ref args);

        return new Application ().run (args);
    }
}
