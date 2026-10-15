#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
mkdir -p .build/ui-preview dist/qa
# ImageRenderer cannot render AppKit-backed scroll/split containers in this
# sandbox. Flatten only the preview copy, preserving production view content.
python3 - <<'PY'
s = open('mac/Sources/BridgeApp.swift').read().replace('@main\nstruct BridgeApp', 'struct BridgeApp', 1).replace('ScrollView {', 'VStack {')
a = s.index('    var body: some View {', s.index('struct BridgeWindow:'))
b = s.index('    private var mainWindow:', a)
s = s[:a] + '    var body: some View { deviceDetail }\n' + s[b:]
for style in ('borderless', 'borderedProminent', 'bordered'):
    s = s.replace('.buttonStyle(.' + style + ')', '.buttonStyle(.plain)')
s = s.replace('ProgressView().padding()', 'Image(systemName: "wifi").font(.largeTitle).padding()')
open('.build/ui-preview/BridgeViews.swift', 'w').write(s)
d = open('mac/Sources/BridgeDownloads.swift').read().replace('ScrollView {', 'VStack {')
d = d.replace('.buttonStyle(.borderedProminent)', '.buttonStyle(.plain)')
d = d.replace('.buttonStyle(.link)', '.buttonStyle(.plain)')
d = d.replace('Bundle.main.url(forResource: "AndroidDownloadQR", withExtension: "png")', 'Optional(URL(fileURLWithPath: "mac/Resources/AndroidDownloadQR.png"))')
open('.build/ui-preview/BridgeDownloadViews.swift', 'w').write(d)
PY
sources=(mac/Sources/*.swift)
sources=(${sources:#mac/Sources/BridgeApp.swift})
sources=(${sources:#mac/Sources/BridgeDownloads.swift})
xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target $(uname -m)-apple-macos13.0 \
  -module-cache-path .build/module-cache "${sources[@]}" .build/ui-preview/BridgeViews.swift .build/ui-preview/BridgeDownloadViews.swift \
  mac/Preview/RenderPreview.swift -o .build/render-mvp-preview
.build/render-mvp-preview dist/qa
