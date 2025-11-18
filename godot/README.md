# Godot Web Export Placeholder

Place the contents of your Godot Web export here. A minimal export produces:

```
godot/
├── index.html
├── mygame.pck
├── mygame.wasm
└── mygame.js
```

Requirements:

- Keep the directory name as `godot` so the iframe in `index.html` resolves correctly.
- Ensure the entry point file is named `index.html`. If your export uses a different file name, update `index.html` in the project root accordingly.
- When building locally, host the project through a web server (`python -m http.server`) instead of opening `index.html` via `file://` to avoid browser sandbox restrictions.

Once the files are present, reload the page and the UI will automatically embed the Godot client in the iframe. Use `window.addEventListener("message", handler)` in your Godot HTML shell or through a custom JavaScript bridge to receive the API payloads sent from `src/main.js`.
