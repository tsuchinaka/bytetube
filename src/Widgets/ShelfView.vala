/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A titled group of results.
 *
 * Results are laid out in a grid that reflows with the width of the window
 * rather than in a horizontal scroller: a grid stays readable at any window
 * size, works with keyboard focus, and does not hide results off the edge.
 */

public class ByteTube.ShelfView : Gtk.Box {
    public Shelf shelf { get; construct; }

    public signal void item_activated (GLib.Object item);

    public ShelfView (Shelf shelf) {
        Object (shelf: shelf);
    }

    construct {
        orientation = Gtk.Orientation.VERTICAL;
        spacing = 12;
        margin_top = 6;
        margin_bottom = 6;

        if (shelf.title != null && shelf.title != "") {
            var header = new Granite.HeaderLabel (shelf.title) {
                size = Granite.HeaderLabel.Size.H3,
                halign = Gtk.Align.START
            };
            append (header);
        }

        var grid = new Gtk.FlowBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            activate_on_single_click = true,
            homogeneous = false,
            column_spacing = 18,
            row_spacing = 18,
            halign = Gtk.Align.FILL,
            valign = Gtk.Align.START
        };

        foreach (var item in shelf.items) {
            grid.append (new ResultCard (item));
        }

        grid.child_activated.connect ((child) => {
            if (child is ResultCard) {
                item_activated (((ResultCard) child).item);
            }
        });

        append (grid);
    }
}
