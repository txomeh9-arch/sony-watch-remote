# 发布隐私说明

公开仓库包含源码、资源、构建配置、脚本和通用测试说明。

发布时已清空 `build-profile.json5` 的签名配置，并移除产品对个人签名配置的引用。仓库不包含证书、私钥、签名密码、设备 Profile、签名 HAP、IDE 缓存、调试日志或个人设备信息。Git 提交使用 GitHub 的 noreply 邮箱。

`.gitignore` 排除签名材料和构建产物。由于 DevEco Studio 的自动签名会修改已跟踪的 `build-profile.json5`，仅依靠忽略规则不能防止这类内容被重新提交；请在提交前运行 `tools/check-publication.mjs`。本地签名文件应始终保存在仓库之外。
