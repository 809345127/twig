# 第三方文件

这个目录里的东西都是**原样拷进来的**，没有改过一个字节。升级时直接覆盖，
不要在这里面打补丁——需要调整的地方一律写在 `web/style.css` 里覆盖它。

拷进来而不是走 npm，是因为 twig 前端刻意不设构建步骤：`web/` 整个被
`//go:embed all:web` 打进二进制，多一个文件就是多一个文件而已。

| 文件 | 来源 | 版本 | 许可 |
|---|---|---|---|
| `diff2html-ui-slim.min.js` | npm `diff2html` → `bundles/js/` | 3.4.56 | MIT（见 `LICENSE.diff2html`） |
| `diff2html.min.css` | npm `diff2html` → `bundles/css/` | 3.4.56 | 同上 |
| `highlight-github.min.css` | npm `highlight.js` → `styles/github.min.css` | 11.11.1 | BSD-3（见 `LICENSE.highlight.js`） |
| `highlight-github-dark.min.css` | npm `highlight.js` → `styles/github-dark.min.css` | 11.11.1 | 同上 |

`diff2html-ui-slim` 这一版**自带 highlight.js 和常用语言包**，所以只需要额外
配一份配色表；语法着色的两份配色表用 `<link media="(prefers-color-scheme: ...)">`
按系统深浅色自动切换。

升级办法：

```bash
npm pack diff2html@<新版本>   # 解开后取 bundles/js/diff2html-ui-slim.min.js 和 bundles/css/diff2html.min.css
npm pack highlight.js@<新版本> # 解开后取 styles/github.min.css 和 styles/github-dark.min.css
```
