# 纸笺声波图标

[矢量母版](../design/icon/app-icon.svg) 根据原版 macOS 图标重绘。100 × 100 画布内，底板宽 86，象牙白纸笺保留右上折角和五条圆角声波。声波直接在纸笺路径中镂空，单色图标也能显示其轮廓。macOS 导出保留透明边缘、底板渐变和轻微投影。

- macOS 导出 16、32、128、256、512 pt 的 1×/2× PNG，生成 [iconset](../assets/AppIcon.iconset)、[ICNS](../assets/AppIcon.icns) 和 1024 px PNG。
- Android 自适应前景把母版的纸笺与折角路径放入 108 dp 画布，缩放到中央直径 66 dp 的安全圆内。背景使用品牌种子色。Android 13+ 的单色层与通知栏的白色剪影共用纸笺镂空，通知图标单独放大。
- Android 12+ 系统启动画面读取自适应图标；旧版本的启动窗口在同一翠绿底色上居中显示前景。内容窗口按系统外观使用两套背景色。
- [512 px 商店图标](../design/icon/play-store.png) 使用满版底色，交给商店添加遮罩。

```sh
python3 -m venv .venv
.venv/bin/pip install resvg-py==0.5.0
.venv/bin/python scripts/make_icon.py
python3 scripts/make_icon.py --check-android
```

图标生成使用固定版本的 resvg 渲染器，Android 运行时无需图像库。修改图形时编辑母版中的 tile、paper、fold。检查 macOS 16/32 px 原尺寸、Android 48 dp 启动器和通知图标的留白、折角与波形；主题色来自 [设计令牌](../design/tokens.json)。
