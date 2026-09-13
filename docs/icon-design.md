# 图标

使用内置 image_gen 生成，保存为 `assets/AppIcon.png`，再通过系统 sips 生成多尺寸 PNG 并封装为 ICNS；没有使用备用 API/CLI 生图。

最终提示词：

> Use case: logo-brand. Asset type: production macOS desktop app icon, square 1024x1024 PNG with true transparency outside the rounded-square icon. Create a simple beautiful restrained premium icon for a local speech-to-text app named Shengjian (voice notes). One softly rounded square tile in muted deep jade / eucalyptus green, subtle soft lighting and a very slight tonal gradient. Centered large ivory white abstract sheet of paper with a small folded upper-right corner; the lower portion of the sheet elegantly incorporates a short sound waveform made of five generous rounded vertical bars in jade green, visually suggesting voice becoming a note. Strong clean silhouette, calm balanced proportions, generous padding, effortlessly legible at 32 pixels. Nearly flat, with a tiny amount of tactile depth and subtle inner shadow only. Front-on orthographic view. Tile occupies about 88% of canvas centered; outside tile genuinely transparent, no backdrop. No letters, no text, no wordmark, no microphone, no decorative objects, no fine lines, no mockup, no multiple variants. Single finished app icon.

原始输出为 1254×1254 RGBA；App 使用 16 至 1024 像素的图标表示。
