/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Videos the user put aside to watch later.
 */

public class ByteTube.WatchLaterView : BrowseView {
    private unowned Library library;

    construct {
        library = Library.get_default ();

        empty_title = _("Watch Later Is Empty");
        empty_description = _("Use the Watch Later button on a video to keep it here.");
        empty_icon = "playlist-symbolic";

        library.watch_later_changed.connect (() => {
            if (get_mapped ()) {
                refresh ();
            }
        });
    }

    protected override async BrowseResult fetch (string? continuation) throws Error {
        var result = new BrowseResult ();
        var shelf = new Shelf ();

        foreach (var video in library.watch_later) {
            shelf.items.add (video);
        }

        if (!shelf.is_empty) {
            result.shelves.add (shelf);
        }

        return result;
    }
}
