const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function({matchComponents, theme}) {
  let iconsDir = path.join(__dirname, "../node_modules/lucide-static/icons")
  let values = {}

  if (!fs.existsSync(iconsDir)) {
    console.warn("lucide-static icons not found. Run 'bun install' in the assets/ directory.")
    return
  }

  fs.readdirSync(iconsDir).forEach(file => {
    if (file.endsWith(".svg")) {
      let name = path.basename(file, ".svg")
      values[name] = {name, fullPath: path.join(iconsDir, file)}
    }
  })

  matchComponents({
    "lucide": ({name, fullPath}) => {
      let content
      try {
        content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
      } catch (err) {
        console.warn(`Failed to read icon: ${fullPath}`)
        return {}
      }

      if (!content.includes("<svg") || !content.includes("</svg>")) {
        console.warn(`Invalid SVG file: ${fullPath}`)
        return {}
      }

      content = encodeURIComponent(content)
      return {
        [`--lucide-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--lucide-${name})`,
        "-webkit-mask-size": "100% 100%",
        "mask": `var(--lucide-${name})`,
        "mask-size": "100% 100%",
        "mask-repeat": "no-repeat",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block"
      }
    }
  }, {values})
})
