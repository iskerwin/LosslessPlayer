# 原音 · LosslessPlayer

iOS 17+ 本地音乐播放器，SwiftUI + AVFoundation，无账号、无服务器、无在线曲库。

## 第一版

- 从“文件”多选导入 FLAC / ALAC（M4A）/ WAV / AIFF / CAF，复制到 App 内后离线播放。
- 歌曲搜索（歌名、艺术家、专辑）、收藏、确认删除；原始文件保留。
- 播放、暂停、拖动进度、切歌、随机、列表循环。
- 后台播放、锁屏与耳机控制，耳机拔出暂停、来电中断处理。
- 本地 JSON 原子保存资料库；每 5 秒及进入后台保存进度，下次启动恢复但不自动播放。
- 展示音源规格、输出设备及系统会话采样率。

格式由设备的 AVAudioFile / AVAudioPlayer 实际解码能力决定。M4A 也可能包含有损 AAC，不能仅凭扩展名认定为无损。文件规格与系统会话采样率均不构成 bit-perfect 的证明；本版本不保证无缝播放。

## 开发

需要 Mac、Xcode（支持 iOS 17 SDK）和 XcodeGen：

```sh
brew install xcodegen
xcodegen generate
open LosslessPlayer.xcodeproj
```

选择 LosslessPlayer scheme、设置自己的 Signing Team，在模拟器或 iPhone 运行。Bundle ID 为 `com.iskerwin.LosslessPlayer`，可按需修改 `project.yml`。生成的项目和 Info.plist 不入库，`project.yml` 是配置来源。

## 验证

GitHub Actions 使用 macOS 生成工程，在可用 iPhone 模拟器执行 `xcodebuild test`，保留 xcresult。单元测试覆盖队列边界、真实 PCM WAV 导入、持久化恢复、收藏、删除保留源文件、无效文件回滚。

GitHub Actions 已完成模拟器编译和 3 项 XCTest（0 失败），并完成 arm64 真机编译。测试结果保存在工作流的 xcresult 附件中；真机音频行为仍需手动验收。

真机验收：FLAC / ALAC / WAV / AIFF 各种位深与采样率、损坏文件、超过 1GB 文件、iCloud 文件下载、中文标签、熄屏连续播放、来电、耳机拔出、蓝牙与 DAC 切换、重启恢复、VoiceOver 与大字体。

## 已知限制与后续

- 当前为多文件导入，暂无文件夹扫描、去重、专辑独立页面、封面或歌单编辑。
- 复制与格式验证目前在主线程执行，大文件导入可能短暂影响界面；后续应迁移到独立导入 worker，增加取消及空间检查。
- 当前播放器使用 AVAudioPlayer；未实现无缝播放、自动匹配音源采样率、逐位输出验证、EQ、DSD、APE、CUE、NAS 或 CarPlay。
- M4A 标签和位深取决于系统返回的信息，未知位深不编造数值。
- 随机播放目前逐次抽选，未实现完整洗牌循环。
- 尚未配置 Apple 签名证书或 TestFlight。CI 会在测试通过后生成 arm64 Debug 未签名 IPA，并发布 GitHub 预发布版本；需自行重新签名安装。
- 不包含第三方音乐文件或在线下载能力。

## 开发版 IPA

main 分支构建通过后，在仓库 Releases 的开发预发布中下载 `LosslessPlayer-dev-unsigned.ipa`。支持 iOS 17+，使用 AltStore 等工具以自己的 Apple ID 重新签名后安装。未签名 IPA 不能直接安装，不是 TestFlight 或 App Store 版本。每个发布附带 `SHA256SUMS.txt`，可验证文件完整性。
