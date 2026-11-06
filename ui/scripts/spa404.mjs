// GitHub Pages has no SPA fallback: serve the app for unknown paths too.
import fs from "node:fs";
fs.copyFileSync("dist/index.html", "dist/404.html");
console.log("spa404: dist/404.html written");
