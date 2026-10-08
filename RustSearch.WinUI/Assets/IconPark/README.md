# IconPark Assets

These icons are rendered by the official ByteDance IconPark SVG package and
bundled locally. The application never downloads icons at runtime.

- Official site: https://iconpark.oceanengine.com/official
- Repository: https://github.com/bytedance/IconPark
- npm package: `@icon-park/svg`, version `1.4.2`
- Package: https://registry.npmjs.org/@icon-park/svg/-/svg-1.4.2.tgz
- Package git revision: `bed2e8d1e451ffc66cbc4def3ba54fcc1f318d9e`
- Package SHA-1: `12838a2549ec8cfc3389089ad335da632bb6285f`
- Package integrity: `sha512-1X0DA+1e0R0liYvw+Nb2BQmF1oEo/wS3o/JYkQYifPJXCGYij2vN9sJf/NNhbzDsJWTg4W2bbzZjJvC7Q4w4oQ==`
- License: Apache-2.0; the unmodified upstream license is in `LICENSE`.

`generate.cjs` calls each upstream icon renderer with the official `outline`
theme, 48px canvas and stroke width 3. The `light` variant uses `#242424`; the
`dark` variant uses `#F2F2F2`. No icon geometry is redrawn or approximated.

To reproduce the bundled assets, download and extract the package above, then
run `node generate.cjs <absolute-path-to-extracted-package>`.

The control's `Kind` matches each SVG filename. The mapping to upstream icon
exports is in `generate.cjs`; `file` maps to `FileText`, and hyphenated folder
names map to `FolderPlus` and `FolderOpen`.
