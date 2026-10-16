# ByteTube — a native viewer for online video feeds
# SPDX-License-Identifier: GPL-3.0-or-later

project(
    'io.github.bytetube.ByteTube',
    'vala', 'c',
    version: '1.0.0',
    meson_version: '>= 0.59.0'
)

gnome = import('gnome')
i18n = import('i18n')

# Domain used by gettext for every _() string in the app
add_project_arguments(
    '-DGETTEXT_PACKAGE="@0@"'.format (meson.project_name ()),
    '-DLOCALEDIR="@0@"'.format (get_option ('prefix') / get_option ('localedir')),
    language: 'c'
)

subdir('data')

gresource = gnome.compile_resources (
    'gresource',
    'data' / 'gresource.xml',
    source_dir: 'data'
)

subdir('src')

# Only wire up translations when the gettext tooling is available, so that the
# project still configures on machines without a full localization stack.
if find_program ('msgfmt', required: false).found () and find_program ('xgettext', required: false).found ()
    subdir('po')
endif

gnome.post_install (
    glib_compile_schemas: true,
    gtk_update_icon_cache: true,
    update_desktop_database: true
)
