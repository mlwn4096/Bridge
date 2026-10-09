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
PY
sources=(mac/Sources/*.swift)
sources=(${sources:#mac/Sources/BridgeApp.swift})
xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos27.0 \
  -module-cache-path .build/module-cache "${sources[@]}" .build/ui-preview/BridgeViews.swift \
  mac/Preview/RenderPreview.swift -o .build/render-mvp-preview
.build/render-mvp-preview dist/qa
