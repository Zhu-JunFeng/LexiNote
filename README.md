# LexiNote

LexiNote 是一款 macOS 菜单栏查词与复习应用。默认按 **⌃⌥L** 打开查词小窗口：如果剪贴板中是一段简短的英文单词或短语，会直接查询。查到的词默认自动记录到单词本；你也可以保存这次遇到的原句和个人笔记。收藏的词会从次日开始进入复习。

## 下载与安装

从 [GitHub Releases](https://github.com/Zhu-JunFeng/LexiNote/releases) 下载最新的 `LexiNote-macOS-universal.zip`，解压后将 `LexiNote.app` 拖入“应用程序”。支持 macOS 14 及更新版本，适用于 Apple 芯片和 Intel Mac。

当前发布包未经过 Apple 公证。首次启动时如被 macOS 阻止，可在“系统设置 → 隐私与安全性”中允许打开。启动后应用只显示在菜单栏。

## 运行

- 需要 macOS 14 或更新版本。项目使用 SwiftUI、AppKit 和 SwiftData。
- 用 Xcode 打开 `LexiNote.xcodeproj`，选择 `LexiNote` scheme 后运行。
- 也可在项目目录执行：

  ```bash
  xcodebuild -project LexiNote.xcodeproj -scheme LexiNote -configuration Debug -derivedDataPath Build/DerivedData CODE_SIGNING_ALLOWED=NO build
  open Build/DerivedData/Build/Products/Debug/LexiNote.app
  ```

应用没有 Dock 图标，启动后在菜单栏显示书签图标与待复习数量。查词、单词本、今日复习、词卡编辑和偏好设置共用一个窗口，默认大小均为 **820×600**；切换页面不会改变手动调整后的尺寸。查词页有“单词本”入口，也可从菜单栏打开各页；子页面点“返回”或按 Esc 返回，查词页按 Esc 隐藏窗口。查词快捷键可在偏好设置中修改，**⌘,** 打开偏好设置。

## 使用

1. 按查词快捷键，或输入单词后按回车查询。中文释义由内置 ECDICT 提供；联网时补充英文解释、例句和音频。查询词先发往 Free Dictionary API；该服务无响应时会发往 EnglishDictionaryAPI。变形词会优先按原形查找，短语先查原样。
2. 查到释义后会默认自动收藏首条中英释义，可以在偏好设置中关闭。点击想保存的释义，按需要补充原句和笔记；窗口内按 **⌘S** 可立即收藏、打开已有词卡，或在没有释义时进入手动填写页。重复收藏不会覆盖已有词卡。
3. 菜单栏打开“今日复习”，先回想再翻卡，用“忘记／模糊／记住”安排下一次复习。
4. 在“单词本”中搜索、编辑或删除词卡，并用 JSON 导入、导出备份。词卡保存在本机，无需账户。
5. 默认按 **⌃⌥S** 可从其他应用读取一次剪贴板并将有效英文词条加入单词本；已有词卡会直接打开，没有词典释义时进入手动填写页。两个全局快捷键都能在偏好设置中修改。

偏好设置中的随机推荐通知默认关闭。开启并允许系统通知后，LexiNote 只在电脑活跃使用时累计时间，每约 30–120 分钟随机推荐一条常用中级新词或到期词卡；空闲时暂停计时。点击新词通知会先打开预览，只有手动点击“加入单词本”才收藏；点击复习提醒会打开现有词卡。LexiNote 退出后不继续产生新推荐。

复习规则：新词次日首次出现；“记住”按 3、7、14、30、60 天逐级延长；“模糊”次日再见；“忘记”10 分钟后再见。日期显示、按天复习和备份文件日期均按北京时间计算；词卡时间戳仍以绝对时间保存。

## 词典与构建

内置的 `LexiNote/Resources/ecdict.sqlite` 从 [ECDICT](https://github.com/skywind3000/ECDICT) 固定版本生成，包含约 77 万条词目；许可文本见 `Licenses/ECDICT-LICENSE`，并随应用打包。需要重新生成数据库时运行 `python3 Scripts/build_ecdict.py`，脚本会校验源 CSV 的 SHA-256。英文在线结果优先来自 [Free Dictionary API](https://dictionaryapi.dev/)，失败时回退到 [EnglishDictionaryAPI](https://englishdictionaryapi.com/)；后者使用 [Wiktionary 的 CC BY-SA 4.0 内容](https://creativecommons.org/licenses/by-sa/4.0/)。词典来源说明随应用打包；网络不可用时，内置词典和已保存的词卡仍可查看。

若之后公开分发，请先复核第三方词典及音频内容的授权与署名要求。

## 后续方向

下一阶段计划考虑跨应用选词直查、原句挖空复习、每日目标和常忘词筛选。再之后可加入拼写与听音测试、Anki 导出、iCloud 同步以及近义词辨析和造句反馈。这些功能尚未包含在第一版。
