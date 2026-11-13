# 索尼遥控 · HUAWEI WATCH 5

独立的 HarmonyOS 手表蓝牙遥控应用，使用 ArkTS / ArkUI，当前版本 **1.0.5**。包名为 `com.mz.sonyremote`，最低兼容 API 23，以 API 24 SDK 编译。

已在 WATCH 5 与 Sony A7M3（ILCE-7M3，手动镜头）上完成 MF 拍照、倒计时、取消、重连和录像开始／停止测试。其他相机尚未逐台验证。

## 功能

- 搜索相机、首次配对、记住上次设备并手动重连。
- MF 拍照、AF 合焦后拍照、单独对焦。默认 MF，适合手动镜头。
- 3 秒倒计时及取消，阻止并发操作和快门自动重试。
- 录像键；收到开始通知后，按钮变红并显示“停止”。
- 进入后台时取消操作、尝试释放快门并断开连接。

本版本不包含 GPS、实时取景、曝光参数控制、B 门或长时间间隔拍摄。

## 相机准备

1. A7M3 固件需为 3.00 或以上。
2. 在“网络 → 蓝牙设置”中打开蓝牙功能，并开启“蓝牙遥控”。
3. 首次使用进入相机“配对”，在手表搜索并选择相机，按提示确认。
4. 使用手动镜头时，在机身选择 MF、单张拍摄，并事先完成对焦。
5. 拍照前将机身切到拍照档；录像使用适合的机身模式。

自动对焦模式会等待合焦反馈，手动对焦模式跳过此步骤。没有收到反馈时应用显示超时，不会自动补拍。快门反馈代表机身响应，不代表存储卡写入已经完成。

录像采用完整按下／释放周期。状态通知可能稍晚到达，请勿连点；已开始录像时，先按“停止”再退出应用。

## 构建

使用 DevEco Studio 打开本目录。命令行脚本通过 `DEVECO_ROOT` 或 `-DevEcoRoot` 接收安装路径：

```powershell
$env:DEVECO_ROOT = 'C:\Program Files\Huawei\DevEco Studio'
.\scripts\build.ps1
```

请把示例路径改为本机的 DevEco Studio 安装目录。默认公开配置不含签名，构建产物位于 `entry/build/default/outputs/default/`。

## 配置自己的签名并安装

1. 按需修改包名，使用自己的华为开发者账号。
2. 连接目标手表的 WLAN 调试，并在手表确认调试授权。
3. 在 DevEco Studio 的“文件 → 项目结构 → 签名配置”启用自动签名并应用。
4. 构建后，用手表当前显示的调试地址执行：

```powershell
.\scripts\deploy.ps1 -Target "WATCH_IP:PORT"
```

公开源码不包含签名安装包、账号证书、密钥、密码或设备 Profile。签名只适用于对应开发者账号与目标设备，请自行生成。提交更改前请运行下方发布检查，避免将 IDE 写入的个人签名配置提交。

## 测试和发布检查

```powershell
& "$env:DEVECO_ROOT\tools\node\node.exe" --test .\tools\test-remote.mjs
& "$env:DEVECO_ROOT\tools\node\node.exe" .\tools\check-publication.mjs
```

27 项测试直接加载实际 `.ets` 协议和连接管理源码，模拟权限、扫描、配对、GATT、AF/MF、反馈超时、取消及前后台切换。模拟测试不能替代硬件验证。详见 [验证记录](VALIDATION.md) 和 [发布隐私说明](PRIVACY.md)。

## 兼容性

目标范围是支持 RMT-P1BT 类蓝牙遥控的 Sony 相机。目前只把 A7M3 列为已实测；其他 Sony 型号需按机型、固件和功能验证。佳能、尼康、富士等品牌尚未适配。

- [Sony A7M3 蓝牙遥控说明](https://helpguide.sony.net/ilc/1720/v1/en/contents/TP0002287120.html)
- [Sony RMT-P1BT 兼容表](https://support.d-imaging.sony.co.jp/www/cscs/accessories/compatibility.php?area=gb&cat=3&lang=en&mdl=RMT-P1BT)

## 工程结构

- `entry/src/main/ets/pages/Index.ets`：设备页、遥控页和说明页。
- `entry/src/main/ets/remote/SonyRemote.ets`：权限、扫描、配对、GATT 和连接状态。
- `entry/src/main/ets/remote/RemoteActions.ets`：拍照、对焦、录像及取消状态机。
- `entry/src/main/ets/remote/SonyProtocol.ets`：广播、命令和状态解析。
- `tools/test-remote.mjs`：协议与模拟平台测试。
- `scripts/`：构建和部署脚本。

## 协议参考

ArkTS 实现为独立编写，参考公开协议资料：

- [Freemote](https://github.com/coral/freemote)
- [Greg Leeds 的 Sony 蓝牙协议研究](https://gregleeds.com/reverse-engineering-sony-camera-bluetooth/)

本项目为独立开发，与 Sony、Huawei 官方无隶属关系。
