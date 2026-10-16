install_data (
    'io.github.bytetube.ByteTube.desktop',
    install_dir: get_option ('datadir') / 'applications'
)

install_data (
    'io.github.bytetube.ByteTube.metainfo.xml',
    install_dir: get_option ('datadir') / 'metainfo'
)

install_data (
    'gschema.xml',
    install_dir: get_option ('datadir') / 'glib-2.0' / 'schemas',
    rename: meson.project_name () + '.gschema.xml'
)

icon_sizes = ['32', '48', '64', '128', '256']

foreach size : icon_sizes
    install_data (
        'icons' / size / (meson.project_name () + '.svg'),
        install_dir: get_option ('datadir') / 'icons' / 'hicolor' / (size + 'x' + size) / 'apps'
    )
endforeach
