fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'bupa-music-source'
author 'BUPA-SCRIPT'
description 'YouTube source for bupa-music'
version '1.0.0'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config.lua',
    'server/sv_base.lua',
    'server/sv_youtube.lua',
    'server/sv_exports.lua',
}

files {
    'web/provider.js',
}

escrow_ignore {
    'config.lua',
}

dependencies {
    'oxmysql',
}
