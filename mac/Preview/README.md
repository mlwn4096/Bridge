# Native component preview QA

Run `scripts/render-mac-preview.sh`. This renders the production dashboard and onboarding SwiftUI content to `dist/qa` in light and dark appearances, using a model initialized with `preview: true` so it starts no network services.

This is component visual QA, not an interactive window test. The sandbox cannot create AppKit hosting windows. The preview copy replaces scroll containers with vertical stacks, omits the navigation sidebar, uses plain button style where AppKit buttons cannot render, and replaces the native spinner with a Wi-Fi symbol. CoreImage QR rendering is unavailable in this CLI environment, so the onboarding preview shows the waiting state. Production source is unchanged by these transformations.

The screenshots verify spacing, contrast, typography, dashboard cards, media layout, and onboarding instructions. They do not verify live QR rendering, Dock activation, native sidebar/settings controls, or pairing with a physical phone.
