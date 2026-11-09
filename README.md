# PasteBox

macOS 剪贴板历史工具，功能对标 PasteNow。原生 Swift / SwiftUI 实现，没有第三方依赖。

## 功能

- 自动记录文本、链接、图片、文件，保留原始的全部剪贴板格式（富文本、HTML 等），粘贴时原样写回
- 重复复制同一内容时不新增条目，而是把原条目移到最前
- `⌘⇧V`（可在设置里改）在鼠标位置呼出面板；输入即搜索，多个关键词之间用空格分隔，按「且」匹配
- `↑` `↓` 选择，`↩` 粘贴，`⇧↩` 粘贴为纯文本，`⌘1`…`⌘9` 直接粘贴第 N 条，`⌘C` 只复制不粘贴，`⌘⌫` 删除，`⇥` 切换分类，`Esc` 先清空搜索、再关闭面板
- 单击卡片即粘贴；右键菜单可以加入分类、移出分类、删除
- 分类：点 `+` 新建。加入分类的条目不受历史条数上限影响
- 跳过密码管理器标记为敏感的内容（nspasteboard.org 约定的 Concealed/Transient 类型），也可以按 Bundle ID 排除指定应用
- 设置里可以一键从 PasteNow 导入历史

## 构建与安装

```bash
./scripts/build.sh --install
```

需要 macOS 13+ 和 Xcode Command Line Tools。脚本会构建 release 版本，打包成 `build/PasteBox.app`，再安装到 `~/Applications` 并启动。

签名默认使用钥匙串里第一个代码签名证书（自签名证书也可以）。签名身份不变，「辅助功能」授权在重新构建后依然有效。如果没有证书，脚本会用 ad-hoc 签名，这样每次构建后都要重新授权。也可以用 `SIGN_IDENTITY="证书名"` 指定证书。

自动粘贴需要在「系统设置 → 隐私与安全性 → 辅助功能」里打开 PasteBox。没有授权时，选中条目只会复制到剪贴板，需要自己按 `⌘V`。

## 数据

`~/Library/Application Support/PasteBox/`：

- `history.sqlite`：条目元数据和可搜索文本
- `payloads/<uuid>.plist`：完整的剪贴板快照
- `thumbs/<uuid>.png`：图片缩略图

## 调试命令

```bash
.build/debug/PasteBox --import-test <空目录>   # 把 PasteNow 历史导入到临时库，并打印统计
.build/debug/PasteBox --render out.png [关键词]  # 离屏渲染面板，不需要屏幕录制权限
.build/debug/PasteBox --write-test <条目 id>    # 把一条历史写回系统剪贴板
.build/release/PasteBox --scroll-bench [步数] [每步像素]  # 用真实历史测滚动耗时和内容高度变化
# 运行中的 PasteBox 收到这个通知时，执行和按快捷键一样的操作（用来逐帧跟踪窗口，不需要模拟按键的权限）
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.liuhaofeng.pastebox.debug.hotkey", $(), $(), true)'
```
