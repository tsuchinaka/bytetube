/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * The channels the user follows.
 */

public class ByteTube.ChannelsView : BrowseView {
    private unowned Library library;

    construct {
        library = Library.get_default ();

        empty_title = _("No Followed Channels");
        empty_description = _("Open a video and follow its channel to keep up with it here.");
        empty_icon = "user-bookmarks-symbolic";

        library.channels_changed.connect (() => {
            if (get_mapped ()) {
                refresh ();
            }
        });
    }

    protected override async BrowseResult fetch (string? continuation) throws Error {
        var result = new BrowseResult ();
        var shelf = new Shelf ();

        foreach (var channel in library.channels) {
            shelf.items.add (channel);
        }

        if (!shelf.is_empty) {
            result.shelves.add (shelf);
        }

        return result;
    }
}
