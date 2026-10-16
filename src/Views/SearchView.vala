/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Results for a search term.
 */

public class ByteTube.SearchView : BrowseView {
    private string query = "";

    construct {
        empty_icon = "system-search-symbolic";
    }

    public void search (string query) {
        this.query = query;

        if (query == "") {
            empty_title = _("Search Videos and Channels");
            empty_description = _("Type into the search field to look for something to watch.");
        } else {
            /// TRANSLATORS: The first %s is the current search term
            empty_title = _("No Results for “%s”").printf (query);
            empty_description = _("Try a different word or a shorter search term.");
        }

        refresh ();
    }

    protected override async BrowseResult fetch (string? continuation) throws Error {
        if (query == "") {
            return new BrowseResult ();
        }

        return yield client.search (query, continuation);
    }
}
