/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * A titled group of results. Everything a request returns is grouped into
 * shelves so that any view can render a response without knowing which
 * endpoint it came from.
 */

public class ByteTube.Shelf : GLib.Object {
    public string? title { get; set; }
    public Gee.ArrayList<GLib.Object> items { get; default = new Gee.ArrayList<GLib.Object> (); }

    public bool is_empty {
        get {
            return items.size == 0;
        }
    }
}
