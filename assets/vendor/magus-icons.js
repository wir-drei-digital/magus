const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

// Custom Magus icons. Mirrors the lucide.js plugin so SVGs in assets/icons
// are exposed as `magus-#{ICON}` Tailwind classes (mask + currentColor).
module.exports = plugin(function({matchComponents, theme}) {
  let iconsDir = path.join(__dirname, "../icons")
  let values = {}

  if (!fs.existsSync(iconsDir)) {
    return
  }

  fs.readdirSync(iconsDir).forEach(file => {
    if (file.endsWith(".svg")) {
      let name = path.basename(file, ".svg")
      values[name] = {name, fullPath: path.join(iconsDir, file)}
    }
  })

  matchComponents({
    "magus": ({name, fullPath}) => {
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
        [`--magus-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--magus-${name})`,
        "-webkit-mask-size": "100% 100%",
        "mask": `var(--magus-${name})`,
        "mask-size": "100% 100%",
        "mask-repeat": "no-repeat",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block"
      }
    }
  }, {values})
})
