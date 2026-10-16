/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Values shared across the app.
 */

namespace ByteTube.Config {
    public const string APP_ID = "io.github.bytetube.ByteTube";
    public const string RESOURCE_PREFIX = "/io/github/bytetube/ByteTube";

    /** Names the sidebar and the view stack agree on. */
    public const string VIEW_DISCOVER = "discover";
    public const string VIEW_SEARCH = "search";
    public const string VIEW_CHANNELS = "channels";
    public const string VIEW_HISTORY = "history";
    public const string VIEW_WATCH_LATER = "watch-later";
    public const string VIEW_ACCOUNT = "account";

    /** How many videos the watch history keeps before dropping the oldest. */
    public const int MAX_HISTORY = 250;

    /** How many views the back stack keeps before dropping the oldest. */
    public const int MAX_BACK_STACK = 24;

    /** Preferred width of one card in a results grid. */
    public const int CARD_WIDTH = 236;

    /** Thumbnails are always shown at the 16:9 of the source material. */
    public const int CARD_HEIGHT = 133;

    /** Width of the related-videos column on the watch page. */
    public const int RELATED_WIDTH = 250;

    /** The player never grows past this, however wide the window is. */
    public const int PLAYER_MAX_HEIGHT = 540;

    /** Below this the watch page stacks the player and the related videos. */
    public const int STACK_BELOW_WIDTH = 940;
}
