import { common } from '@kit.AbilityKit';
import { CameraDevice, RemoteView, remote } from '../remote/SonyRemote';

@Entry
@Component
struct Index {
  @State view: RemoteView = new RemoteView();
  @State page: string = 'devices';
  @State autoFocus: boolean = false;
  @State delaySeconds: number = 0;
  private unsubscribe: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.unsubscribe = remote.subscribe((view: RemoteView): void => {
      const becameReady = !this.view.ready && view.ready;
      this.view = view;
      if (becameReady) { this.page = 'remote'; }
    });
    remote.initialize(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  onBackPress(): boolean {
    if (this.page === 'help') {
      this.page = this.view.ready ? 'remote' : 'devices';
      return true;
    }
    if (this.page === 'remote') {
      this.page = 'devices';
      return true;
    }
    return false;
  }

  private connectionPending(): boolean {
    return this.view.phase === 'connecting' || this.view.phase === 'pairing' ||
      this.view.phase === 'discovering' || this.view.phase === 'closing';
  }

  @Builder
  title(text: string) {
    Text(text).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#F4F6F9')
      .height(20).maxLines(1)
  }

  @Builder
  deviceRow(device: CameraDevice) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 2 }) {
        Text(device.name).fontSize(12).fontColor('#F4F6F9').maxLines(1)
        Text((device.pairing ? '可配对' : '点击连接') + ' · ' + device.rssi.toString() + ' dBm')
          .fontSize(9).fontColor('#AEB9C9').maxLines(1)
      }.width('100%').padding(7)
    }
    .width('100%').height(43).borderRadius(14).backgroundColor('#1A2431')
    .enabled(!this.connectionPending() && !this.view.ready)
    .onClick(() => remote.connect(this.getUIContext().getHostContext() as common.UIAbilityContext, device))
  }

  @Builder
  devicePage() {
    Scroll() {
      Column({ space: 7 }) {
        this.title('索尼遥控')
        Text(this.view.message).fontSize(11).fontColor('#AEB9C9').textAlign(TextAlign.Center)
          .maxLines(3).width('100%')
        if (this.view.ready) {
          Button('返回遥控').height(32).fontSize(13).width('100%').backgroundColor('#EA7946')
            .onClick(() => { this.page = 'remote'; })
          Button('断开相机').height(30).fontSize(12).width('100%').backgroundColor('#243142')
            .onClick(() => remote.disconnect())
        } else if (this.connectionPending()) {
          LoadingProgress().width(26).height(26).color('#FF915A')
          Button('取消连接').height(32).fontSize(12).width('100%').backgroundColor('#243142')
            .onClick(() => remote.disconnect())
        } else {
          Button(this.view.scanning ? '停止搜索' : '搜索相机')
            .height(34).fontSize(14).width('100%').backgroundColor('#EA7946')
            .onClick(() => {
              if (this.view.scanning) { remote.stopScan(); }
              else { remote.scan(this.getUIContext().getHostContext() as common.UIAbilityContext); }
            })
          if (this.view.lastId.length > 0 && !this.view.scanning) {
            Button('重连 ' + this.view.lastName).height(30).fontSize(11).width('100%')
              .backgroundColor('#243142')
              .onClick(() => remote.reconnect(this.getUIContext().getHostContext() as common.UIAbilityContext))
          }
        }
        ForEach(this.view.devices, (device: CameraDevice) => {
          this.deviceRow(device)
        }, (device: CameraDevice) => device.id)
        if (this.view.devices.length === 0 && !this.view.ready && !this.connectionPending()) {
          Text('相机：网络 → 蓝牙遥控 → 开\n首次使用再进入“配对”')
            .fontSize(10).fontColor('#8998AC').textAlign(TextAlign.Center).lineHeight(15)
        }
        Button('使用说明').height(28).fontSize(11).backgroundColor('#151D28')
          .onClick(() => { this.page = 'help'; })
      }.width('100%').padding({ top: 26, bottom: 27, left: 27, right: 27 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }

  @Builder
  remotePage() {
    Column({ space: 4 }) {
      Text('索尼遥控').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#F4F6F9').height(16)
      Text(this.view.ready ? this.view.cameraName : '相机未连接')
        .fontSize(10).fontColor(this.view.ready ? '#92D5AF' : '#EAAF80').height(12).maxLines(1)
      Button(this.view.busy ? (this.view.countdown > 0 ? this.view.countdown.toString() + ' · 取消' : '取消')
        : '拍照')
        .width(104).height(56).fontSize(22).fontWeight(FontWeight.Bold)
        .backgroundColor(this.view.busy ? '#8B4936' : '#EA7946')
        .enabled(this.view.ready || this.view.busy)
        .onClick(() => {
          if (this.view.busy) { remote.cancel(); }
          else { remote.capture(this.autoFocus, this.delaySeconds); }
        })
      Row({ space: 8 }) {
        Button('对焦').width(64).height(28).fontSize(12).backgroundColor('#243142')
          .enabled(this.view.ready && !this.view.busy && this.autoFocus).onClick(() => remote.focus())
        Button(this.view.recordingKnown && this.view.recording ? '停止' : '录像键')
          .width(74).height(28).fontSize(12)
          .backgroundColor(this.view.recordingKnown && this.view.recording ? '#9C3943' : '#243142')
          .enabled(this.view.ready && !this.view.busy).onClick(() => remote.record())
      }
      Row({ space: 6 }) {
        Button(this.autoFocus ? '自动对焦' : '手动对焦')
          .height(22).fontSize(10).backgroundColor('#151D28')
          .enabled(!this.view.busy).onClick(() => { this.autoFocus = !this.autoFocus; })
        Button(this.delaySeconds === 0 ? '无延时' : '延时 3 秒')
          .height(22).fontSize(10).backgroundColor('#151D28')
          .enabled(!this.view.busy).onClick(() => { this.delaySeconds = this.delaySeconds === 0 ? 3 : 0; })
      }
      Text(this.view.message).fontSize(10).fontColor('#B9C3D1').maxLines(1).height(16)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        .onClick(() => { this.page = 'help'; })
      Row({ space: 18 }) {
        Text('设备').fontSize(10).fontColor('#FFAB80').height(20).width(44)
          .textAlign(TextAlign.Center).onClick(() => { this.page = 'devices'; })
        Text('说明').fontSize(10).fontColor('#FFAB80').height(20).width(44)
          .textAlign(TextAlign.Center).onClick(() => { this.page = 'help'; })
      }
    }
    .width('100%').height('100%').padding({ top: 19, bottom: 16, left: 24, right: 24 })
  }

  @Builder
  helpPage() {
    Scroll() {
      Column({ space: 9 }) {
        this.title('使用说明')
        Text('A7M3 固件需 3.00 或以上。\n相机：网络 → 蓝牙设置 → 蓝牙功能：开；蓝牙遥控：开。')
          .fontSize(11).fontColor('#D0D8E4').lineHeight(16).width('100%')
        Text('首次：相机进入“配对”，手表搜索相机，选择设备并在相机上确认。已配对后可直接重连。')
          .fontSize(11).fontColor('#D0D8E4').lineHeight(16).width('100%')
        Text('先用单张拍摄测试。自动对焦模式会等待合焦；手动对焦模式要求你先在机身完成对焦。')
          .fontSize(11).fontColor('#D0D8E4').lineHeight(16).width('100%')
        Text('当前版本适合前台操作。返回表盘时会取消任务、尝试释放快门并断开。暂不支持 B 门和长时间间隔拍摄。')
          .fontSize(11).fontColor('#D0D8E4').lineHeight(16).width('100%')
        Text('蓝牙遥控开启时，A7M3 的手机位置关联与自动节电会受到影响。结束后请在机身关闭蓝牙遥控。')
          .fontSize(11).fontColor('#D0D8E4').lineHeight(16).width('100%')
        Text('当前状态：' + this.view.message).fontSize(11).fontColor('#FFAB80')
          .lineHeight(16).width('100%')
        if (this.view.logs.length > 0) {
          Text('连接记录').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#F4F6F9')
          ForEach(this.view.logs, (line: string, index: number) => {
            Text(line).fontSize(9).fontColor('#8998AC').width('100%').lineHeight(13)
          }, (line: string, index: number) => index.toString() + line)
        }
        Button('返回').height(30).fontSize(12).width('100%').backgroundColor('#243142')
          .onClick(() => { this.page = this.view.ready ? 'remote' : 'devices'; })
      }.width('100%').padding({ top: 26, bottom: 28, left: 30, right: 30 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }

  build() {
    Stack() {
      if (this.page === 'help') {
        this.helpPage()
      } else if (this.page === 'remote') {
        this.remotePage()
      } else {
        this.devicePage()
      }
    }.width('100%').height('100%').backgroundColor('#080B10')
  }
}
