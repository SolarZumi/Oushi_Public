# 偶拾 · Oushi

把相册变成一叠卡片：每次随机抽一组照片和视频，左右滑保留，往下拉放进待删除，检查后再真正删除。看过的不会再出现，直到整个相册翻完一遍。

[English](README.md)

## 功能

- 每组 15 到 50 项照片和视频，也可选择不限数量，顺序可随机、从最近开始或从最老开始
- 左右滑保留，下拉放进待删除，每一步都可撤销
- 待删除列表：确认前全部仍在相册里，可部分或全部恢复、删除
- 收藏直接写入系统「照片」
- 视频在卡片上播放；照片和视频支持 HDR；触感反馈
- 可选的 iCloud 同步浏览记录（只同步记录，不同步照片）
- 20 种语言

## 现状

这个仓库是偶拾的完整源码，作为一份基础实现公开，供想做同类软件的人参考。作者在私有仓库里开发，会视情况把新版本同步到这里，不一定每次发版都同步，所以这里的代码可能落后于 App Store 上的版本。Issue 和 Pull Request 不会处理。你可以派生并维护自己的版本。本仓库的许可适用于这里发布的代码。

## 环境要求

- Xcode 27 或更新
- iOS 26 或更新

## 构建

1. 打开 `App/偶拾.xcodeproj`，选择 **Oushi** scheme。
2. 工程不带开发团队：把 `App/Config/Local.xcconfig.example` 复制为 `App/Config/Local.xcconfig` 填入你的团队 ID（或在 *Signing & Capabilities* 里选）。
3. `App/Config/Identity.xcconfig` 里是 bundle identifier、iCloud 容器标识和“关于”页链接的网站（技术支持、隐私政策、使用条款）的占位值，改成你自己的即可；权限文件、Info.plist 和代码都从这里读取。装到真机需要你团队名下的 iCloud 容器，或者去掉 iCloud 能力：Xcode 签不出别人团队的容器。模拟器不改也能构建。
4. 构建运行。

发布自己的应用前，请更换产品名称和图标；构建自用版本无需更换。

`swift test --package-path App/OushiCore` 在 Mac 上跑浏览逻辑的测试。

## 目录

```
App/Config/     构建设置（xcconfig）；Identity.xcconfig 放 bundle identifier、iCloud 容器和网站，
                不进 git 的 Local.xcconfig 放开发团队
App/OushiCore/  Swift 包：浏览记录（已浏览项目、待删除项目）、当前一组、SwiftData 存储及其 iCloud 镜像、会话、
                滑动物理；带测试
App/Oushi/
  App/          入口与根视图
  Library/      PhotoKit 访问、图片加载、收藏、标识查询
  Review/       照片列表、使用教程、卡片、工具栏、视频播放、设置
  Pending/      待删除卡片及展开后的全屏界面
  Background/   照片色彩光团背景（Metal 着色器）
  Shared/       动效常量、帧时钟、控件、仅模拟器用的截图姿态
  Resources/    由 Localization/ 生成的字符串目录
Localization/   源字符串（keys.json）与各语言译文；build_catalog.py 生成目录并与代码核对
Screenshots/    模拟器原截图
```

## 本地化

字符串以简体中文原文为键。`Localization/keys.json` 列出每个键、英文译文和出现位置；`Localization/<语言>.json` 是该语言的译文。改完后运行 `python3 Localization/build_catalog.py` 重新生成 `App/Oushi/Resources/*.xcstrings`，脚本会校验占位符。

## 许可

版权所有 © 2026 Zuming Hu。

代码和文档采用 GNU GPL 第 3 版，并附有依据第 7 条制定的补充许可与要求。完整条款见 [LICENSE](LICENSE)、[ADDITIONAL-TERMS.md](ADDITIONAL-TERMS.md)；名称和指定图像素材另见 [BRANDING.md](BRANDING.md)。

- **自用**：可以自行使用和修改，无需公开修改内容，也无需额外设置对外署名页面。
- **分发**：向他人分发原版或基于代码开发的版本时，无论是否收费、通过什么渠道、用于什么平台，都须遵守 GPL 和适用的附加条款。移植或转换编程语言不因此免除这些要求。
- **源码**：按 GPL 提供与分发版本对应的完整源码；仅链接原项目仓库不能替代提供自己修改的源码。GPL 不要求在所有情况下都向全社会公开源码。
- **来源**：保留原项目名称“偶拾（Oushi）”、原作者“Zuming Hu”和原项目仓库地址。有交互界面的软件应在应用内可访问的法律声明页面中显示；没有交互界面的，在随附声明或文档中保留。实际修改过的版本还须注明修改。
- **名称和图标**：发布自己的应用时使用自己的名称和图标。可以在来源声明和如实介绍原项目时提及“偶拾”和“Oushi”，不得冒充原版或暗示原作者认可你的版本。

这份摘要不代替完整条款。分发渠道的补充许可见附加条款第六节。独立实现相似功能本身不使程序受本许可约束。

App 内可离线阅读完整的许可文件。修改根目录的许可文件后，运行 `python3 Tools/sync_legal.py` 更新随 App 提供的副本；运行 `python3 Tools/sync_legal.py --check` 检查是否一致。
