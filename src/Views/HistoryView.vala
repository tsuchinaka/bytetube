/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Videos the user has already opened.
 */

public class ByteTube.HistoryView : BrowseView {
    private unowned Library library;

    construct {
        library = Library.get_default ();

        empty_title = _("No Watch History");
        empty_description = _("Videos you open show up here so you can find them again.");
        empty_icon = "document-open-recent-symbolic";

        library.history_changed.connect (() => {
            if (get_mapped ()) {
                refresh ();
            }
        });
    }

    protected override async BrowseResult fetch (string? continuation) throws Error {
        var result = new BrowseResult ();
        var shelf = new Shelf ();

        foreach (var video in library.history) {
            shelf.items.add (video);
        }

        if (!shelf.is_empty) {
            result.shelves.add (shelf);
        }

        return result;
    }
}
