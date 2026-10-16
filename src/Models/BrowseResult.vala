/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Everything one request to the video service returned.
 */

public class ByteTube.BrowseResult : GLib.Object {
    public Gee.ArrayList<Shelf> shelves { get; default = new Gee.ArrayList<Shelf> (); }

    /** Set when the request was about a single video (the watch page). */
    public Video? primary { get; set; }

    /** Set when the request was about a single channel. */
    public Channel? channel { get; set; }

    /** Token used to ask for the next page of results, if there is one. */
    public string? continuation { get; set; }

    public bool is_empty {
        get {
            foreach (var shelf in shelves) {
                if (!shelf.is_empty) {
                    return false;
                }
            }

            return primary == null;
        }
    }
}
