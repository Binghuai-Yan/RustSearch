// Run with a locally extracted @icon-park/svg 1.4.2 package directory.
const fs = require('node:fs');
const path = require('node:path');

const packageDirectory = path.resolve(process.argv[2]);
const metadata = require(path.join(packageDirectory, 'package.json'));
if (metadata.name !== '@icon-park/svg' || metadata.version !== '1.4.2') {
    throw new Error('Expected the official @icon-park/svg 1.4.2 package.');
}

const icons = {
    search: 'Search', close: 'Close', history: 'History', setting: 'Setting',
    refresh: 'Refresh', 'folder-plus': 'FolderPlus', 'folder-open': 'FolderOpen',
    delete: 'Delete', pause: 'Pause', play: 'Play', save: 'Save', copy: 'Copy',
    left: 'Left', right: 'Right', file: 'FileText', sun: 'Sun', moon: 'Moon',
    logout: 'Logout', more: 'More', inbox: 'Inbox', folder: 'Folder',
};

for (const [theme, fill] of Object.entries({ light: '#242424', dark: '#F2F2F2' })) {
    const directory = path.join(__dirname, theme);
    fs.mkdirSync(directory, { recursive: true });
    for (const [kind, component] of Object.entries(icons)) {
        const render = require(path.join(packageDirectory, 'lib', 'icons', `${component}.js`)).default;
        const svg = render({ theme: 'outline', size: 48, fill, strokeWidth: 3 });
        fs.writeFileSync(path.join(directory, `${kind}.svg`), `${svg}\n`, 'utf8');
    }
}
fs.copyFileSync(path.join(packageDirectory, 'LICENSE'), path.join(__dirname, 'LICENSE'));
console.log(`Generated ${Object.keys(icons).length * 2} official IconPark SVG files.`);
