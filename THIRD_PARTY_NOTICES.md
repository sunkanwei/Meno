# 第三方说明

## m1ddc

Meno 的 `Platform/M1DDCBridge/` 包含从 [waydabber/m1ddc](https://github.com/waydabber/m1ddc) 派生的代码，用于向 Apple Silicon Mac 连接的 Philips 显示器发送 DDC/CI 输入源命令。

Copyright (c) 2021 waydabber

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Clipboard feedback animations

Meno 的剪贴板反馈使用以下从 LottieFiles 下载的动画：

- 粘贴：[Check mark success](https://app.lottiefiles.com/animation/b3e3130f-2d30-4bde-86c1-3c4fc66000aa)
- 复制与剪切：[Copy Green](https://app.lottiefiles.com/animation/8534f78a-85bf-4095-8141-dc399f78966c)

原始 Lottie JSON 保留在 `MenoApp/Resources/ClipboardFeedback/Source/`，应用运行时使用经配色、尺寸和透明区域调整后生成的透明 APNG。
这两项动画依照 [Lottie Simple License](https://lottiefiles.com/page/license) 使用。

## Clipboard paste sound

粘贴反馈使用项目所有者提供的 `apple-pay-success.mp3`，在应用内重命名为
`clipboard-paste-success.mp3`。该文件的使用授权由项目所有者负责确认。
