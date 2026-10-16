/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A message with an optional action, shown above the content it concerns.
 *
 * GTK's own info bar is deprecated with no replacement, so this is a plain
 * box in a revealer: an icon naming the severity, the message, and at most one
 * button. It is empty and hidden until something has to be said.
 */

public class ByteTube.NoticeBar : Gtk.Box {
    public signal void action (int response);

    public bool revealed {
        get { return revealer.reveal_child; }
        set { revealer.reveal_child = value; }
    }

    private Gtk.Revealer revealer;
    private Gtk.Image icon;
    private Gtk.Label message_label;
    private Gtk.Button action_button;
    private int action_response = 0;

    public NoticeBar () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            hexpand: true
        );
    }

    construct {
        icon = new Gtk.Image ();

        message_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            hexpand = true
        };

        action_button = new Gtk.Button () {
            valign = Gtk.Align.CENTER,
            visible = false
        };
        action_button.add_css_class (Granite.CssClass.SUGGESTED);
        action_button.clicked.connect (() => action (action_response));

        var dismiss = new Gtk.Button.from_icon_name ("close-symbolic") {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Dismiss")
        };
        dismiss.add_css_class (Granite.STYLE_CLASS_FLAT);
        dismiss.clicked.connect (() => { revealed = false; });

        var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 12,
            margin_end = 6
        };
        bar.add_css_class (Granite.CssClass.CARD);
        bar.append (icon);
        bar.append (message_label);
        bar.append (action_button);
        bar.append (dismiss);

        revealer = new Gtk.Revealer () {
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
            reveal_child = false,
            child = bar
        };

        append (revealer);
    }

    /**
     * Shows a message. The action button is only there when both a label and a
     * response for it are given.
     */
    public void set_message (
        Gtk.MessageType kind,
        string message,
        string? action_label = null,
        int response = 0
    ) {
        icon.icon_name = kind == Gtk.MessageType.ERROR
            ? "dialog-error-symbolic"
            : "dialog-information-symbolic";
        message_label.label = message;

        if (action_label != null && action_label != "" && response != 0) {
            action_response = response;
            action_button.label = action_label;
            action_button.visible = true;
        } else {
            action_button.visible = false;
        }

        revealed = true;
    }
}
