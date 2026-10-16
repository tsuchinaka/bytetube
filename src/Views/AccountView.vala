/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The account the app is signed in with.
 *
 * Signing in is only about being allowed to watch. The app never asks for a
 * password: it shows a code the user approves where they are already signed
 * in. Whatever proves the account is kept in the user's own data directory,
 * so signing in survives a restart.
 */

public class ByteTube.AccountView : Gtk.Box {
    public signal void signed_out ();
    public signal void video_activated (ByteTube.Video video);
    public signal void channel_activated (ByteTube.Channel channel);

    private unowned TokenStore tokens;
    private unowned Library library;

    private Thumbnail avatar;
    private Granite.HeaderLabel name_label;
    private Gtk.Label detail_label;
    private Gtk.Button action_button;
    private Gtk.Box sections_box;
    private Gtk.Label empty_label;
    private Gtk.Box history_slot;
    private Gtk.Box later_slot;
    private Gtk.Box subs_slot;
    private StatusView status;
    private Gtk.Stack stack;

    private Granite.HeaderLabel code_label;
    private Gtk.Label code_url_label;
    private Gtk.Label code_wait_label;
    private Gtk.Label code_error_label;
    private Gtk.Spinner code_spinner;
    private Gtk.Box code_wait_row;
    private Gtk.Button code_open_button;
    private Gtk.Button code_retry_button;
    private DeviceCode? pending_code = null;
    private GLib.Cancellable poll_cancel = new GLib.Cancellable ();

    public AccountView () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            hexpand: true,
            vexpand: true
        );
    }

    construct {
        tokens = TokenStore.get_default ();
        library = Library.get_default ();

        status = new StatusView ();
        status.action_requested.connect (() => refresh ());

        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            hexpand = true,
            vexpand = true
        };
        stack.add_named (build_details (), "details");
        stack.add_named (build_code (), "code");
        stack.add_named (status, "status");

        append (stack);

        tokens.changed.connect (refresh);
        library.history_changed.connect (refresh);
        library.watch_later_changed.connect (refresh);
        library.channels_changed.connect (refresh);
        refresh ();
    }

    public override void dispose () {
        poll_cancel.cancel ();
        base.dispose ();
    }

    private Gtk.Widget build_details () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            hexpand = true,
            vexpand = true,
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };

        avatar = new Thumbnail.avatar ("", 96) { halign = Gtk.Align.CENTER };
        box.append (avatar);

        name_label = new Granite.HeaderLabel ("") {
            size = Granite.HeaderLabel.Size.H2,
            halign = Gtk.Align.CENTER
        };
        box.append (name_label);

        detail_label = new Gtk.Label ("") {
            halign = Gtk.Align.CENTER,
            justify = Gtk.Justification.CENTER
        };
        detail_label.add_css_class (Granite.CssClass.DIM);
        detail_label.add_css_class (Granite.CssClass.SMALL);
        box.append (detail_label);

        action_button = new Gtk.Button () { halign = Gtk.Align.CENTER };
        action_button.clicked.connect (() => on_action ());
        box.append (action_button);

        sections_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            hexpand = true,
            vexpand = true
        };
        empty_label = new Gtk.Label (_("Videos you watch, save and follow will show up here.")) {
            halign = Gtk.Align.CENTER,
            justify = Gtk.Justification.CENTER,
            wrap = true,
            margin_top = 12,
            visible = false
        };
        empty_label.add_css_class (Granite.CssClass.DIM);
        box.append (empty_label);

        history_slot = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        later_slot = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        subs_slot = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        sections_box.append (history_slot);
        sections_box.append (later_slot);
        sections_box.append (subs_slot);
        box.append (sections_box);

        return new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = box
        };
    }

    /** Reloads the account from the sign-in, or offers to sign in. */
    public void refresh () {
        if (tokens.signed_in) {
            avatar.load_uri (tokens.account_avatar);
            name_label.label = tokens.account_name != ""
                ? tokens.account_name
                : _("Signed In");
            detail_label.label = tokens.account_email != ""
                ? tokens.account_email
                : _("Your sign-in is kept so you stay signed in.");
            action_button.label = _("Sign Out");

            fill_sections ();
        } else {
            name_label.label = _("Not Signed In");
            detail_label.label = _("Sign in to watch videos on this service.");
            action_button.label = _("Sign In with a Code");
            avatar.load_uri ("");
            clear_sections ();
        }

        // A code being approved keeps its page; the poll leaves it itself.
        if (stack.visible_child_name != "code") {
            stack.visible_child_name = "details";
        }
    }

    /**
     * The account's own corners of the app: what was watched and saved here,
     * and which channels are followed. Anything missing just stays hidden,
     * and a fresh account gets a hint instead of an empty page.
     */
    private void fill_sections () {
        clear_sections ();

        if (!tokens.signed_in) {
            return;
        }

        fill_videos (history_slot, _("History"), library.history);
        fill_videos (later_slot, _("Watch Later"), library.watch_later);
        fill_channels (subs_slot, _("Followed Channels"), library.channels);

        empty_label.visible = !history_slot.visible
            && !later_slot.visible
            && !subs_slot.visible;
    }

    /** A shelf of the first videos, or nothing when there are none to show. */
    private void fill_videos (Gtk.Box slot, string title, Gee.ArrayList<Video> videos) {
        clear_slot (slot);

        var shelf = new Shelf () { title = title };
        foreach (var video in videos) {
            if (shelf.items.size >= SECTION_SIZE) {
                break;
            }

            shelf.items.add (video);
        }

        if (shelf.is_empty) {
            return;
        }

        append_shelf (slot, shelf);
    }

    /** A shelf of the first channels, or nothing when there are none to show. */
    private void fill_channels (Gtk.Box slot, string title, Gee.ArrayList<Channel> channels) {
        clear_slot (slot);

        var shelf = new Shelf () { title = title };
        foreach (var channel in channels) {
            if (shelf.items.size >= SECTION_SIZE) {
                break;
            }

            shelf.items.add (channel);
        }

        if (shelf.is_empty) {
            return;
        }

        append_shelf (slot, shelf);
    }

    private void append_shelf (Gtk.Box slot, Shelf shelf) {
        var view = new ShelfView (shelf);
        view.item_activated.connect (on_shelf_item);
        slot.append (view);
        slot.visible = true;
    }

    private void on_shelf_item (GLib.Object item) {
        if (item is Video) {
            video_activated ((Video) item);
        } else if (item is Channel) {
            channel_activated ((Channel) item);
        }
    }

    private static void clear_slot (Gtk.Box slot) {
        var child = slot.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            slot.remove (child);
            child = next;
        }

        slot.visible = false;
    }

    private void clear_sections () {
        empty_label.visible = false;
        clear_slot (history_slot);
        clear_slot (later_slot);
        clear_slot (subs_slot);
    }

    /** How many entries each section on the page shows. */
    private const int SECTION_SIZE = 12;

    /**
     * The code page: a code to approve elsewhere, and somewhere to approve
     * it. Approving returns tokens and the page is left behind signed in.
     */
    private Gtk.Widget build_code () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };

        var instruction = new Gtk.Label (_("Enter this code where you are already signed in:")) {
            halign = Gtk.Align.CENTER,
            justify = Gtk.Justification.CENTER,
            wrap = true
        };
        box.append (instruction);

        code_label = new Granite.HeaderLabel ("") {
            size = Granite.HeaderLabel.Size.H1,
            halign = Gtk.Align.CENTER
        };
        box.append (code_label);

        code_url_label = new Gtk.Label ("") {
            halign = Gtk.Align.CENTER,
            selectable = true
        };
        code_url_label.add_css_class (Granite.CssClass.DIM);
        box.append (code_url_label);

        code_wait_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            halign = Gtk.Align.CENTER
        };
        code_spinner = new Gtk.Spinner ();
        code_wait_row.append (code_spinner);
        code_wait_label = new Gtk.Label ("");
        code_wait_row.append (code_wait_label);
        box.append (code_wait_row);

        code_error_label = new Gtk.Label ("") {
            halign = Gtk.Align.CENTER,
            justify = Gtk.Justification.CENTER,
            wrap = true,
            visible = false
        };
        code_error_label.add_css_class (Granite.CssClass.ERROR);
        box.append (code_error_label);

        var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            halign = Gtk.Align.CENTER,
            margin_top = 6
        };

        code_open_button = new Gtk.Button.with_label (_("Open Browser"));
        code_open_button.add_css_class (Granite.CssClass.SUGGESTED);
        code_open_button.clicked.connect (() => on_code_open ());
        buttons.append (code_open_button);

        code_retry_button = new Gtk.Button.with_label (_("Try Again")) {
            visible = false
        };
        code_retry_button.clicked.connect (() => show_code_page ());
        buttons.append (code_retry_button);

        var cancel_button = new Gtk.Button.with_label (_("Cancel"));
        cancel_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        cancel_button.clicked.connect (() => on_code_cancel ());
        buttons.append (cancel_button);

        box.append (buttons);

        return box;
    }

    /** Asks for a fresh code and waits for it to be approved. */
    private void show_code_page () {
        poll_cancel.cancel ();
        poll_cancel = new GLib.Cancellable ();
        pending_code = null;

        code_label.label = "";
        code_url_label.label = "";
        code_error_label.visible = false;
        code_retry_button.visible = false;
        code_open_button.sensitive = false;
        code_wait_row.visible = true;
        code_spinner.start ();
        code_wait_label.label = _("Contacting the sign-in service…");
        stack.visible_child_name = "code";

        DeviceAuth.request_code.begin ((obj, res) => {
            DeviceCode code;
            try {
                code = DeviceAuth.request_code.end (res);
            } catch (Error e) {
                show_code_error (e.message);
                return;
            }

            if (poll_cancel.is_cancelled ()) {
                return;
            }

            pending_code = code;
            code_label.label = code.user_code;
            code_url_label.label = code.verification_url;
            code_open_button.sensitive = true;
            code_wait_label.label = _("Waiting for approval…");

            DeviceAuth.poll_for_approval.begin (code, poll_cancel, (poll_obj, poll_res) => {
                if (poll_cancel.is_cancelled ()) {
                    return;
                }

                try {
                    tokens.save_tokens (DeviceAuth.poll_for_approval.end (poll_res));
                } catch (Error e) {
                    show_code_error (e.message);
                    return;
                }

                stack.visible_child_name = "details";
            });
        });
    }

    private void show_code_error (string message) {
        code_spinner.stop ();
        code_wait_row.visible = false;
        code_open_button.sensitive = false;
        code_error_label.label = message;
        code_error_label.visible = true;
        code_retry_button.visible = true;
    }

    /** Opens where the code is approved, in the user's own browser. */
    private void on_code_open () {
        if (pending_code == null) {
            return;
        }

        Gtk.Window? parent = null;
        var root = get_root ();
        if (root is Gtk.Window) {
            parent = (Gtk.Window) root;
        }

        var launcher = new Gtk.UriLauncher (pending_code.verification_url);
        launcher.launch.begin (parent, null);
    }

    /** Gives up waiting and goes back. */
    private void on_code_cancel () {
        poll_cancel.cancel ();
        pending_code = null;
        stack.visible_child_name = "details";
        refresh ();
    }

    private void on_action () {
        if (tokens.signed_in) {
            tokens.clear ();
            signed_out ();
            return;
        }

        show_code_page ();
    }

}
