import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { access, ble, connection, constant } from '@kit.ConnectivityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommandTransport, RemoteActions, pause } from './RemoteActions';
import { COMMAND_CHARACTERISTIC, STATUS_CHARACTERISTIC, REMOTE_SERVICE,
  parseAdvertisement, parseManufacturer, parseNotification } from './SonyProtocol';

export class CameraDevice {
  id: string = '';
  name: string = 'Sony 相机';
  rssi: number = -100;
  pairing: boolean = false;
}

export class RemoteView {
  phase: string = 'idle';
  ready: boolean = false;
  scanning: boolean = false;
  busy: boolean = false;
  countdown: number = 0;
  cameraName: string = '';
  message: string = '请先打开相机的蓝牙遥控';
  lastId: string = '';
  lastName: string = '';
  recordingKnown: boolean = false;
  recording: boolean = false;
  focusReady: boolean = false;
  devices: CameraDevice[] = [];
  logs: string[] = [];
}

async function deadline<T>(work: Promise<T>, timeout: number, message: string): Promise<T> {
  let timer: number = -1;
  try {
    return await Promise.race<T>([work, new Promise<T>((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), timeout);
    })]);
  } finally { clearTimeout(timer); }
}

function errorText(error: Error): string {
  const detail = error as BusinessError;
  if (detail.code === 201) { return '蓝牙权限未授权，请在设置中允许'; }
  if (detail.code === 801) { return '手表系统未开放所需蓝牙能力'; }
  if (detail.code === 2900003) { return '请先在手表设置中打开蓝牙'; }
  if (detail.code === 2901005 || detail.code === 2901006 || detail.code === 2901007) {
    return '连接未加密或未授权，请重新配对';
  }
  return detail.code ? error.message + ' (' + detail.code.toString() + ')' : error.message;
}

class BleCommandTransport implements CommandTransport {
  private sender: (bytes: Uint8Array) => Promise<void>;
  constructor(sender: (bytes: Uint8Array) => Promise<void>) { this.sender = sender; }
  write(bytes: Uint8Array): Promise<void> { return this.sender(bytes); }
}

export class SonyRemote {
  private state: RemoteView = new RemoteView();
  private listeners: Array<(state: RemoteView) => void> = [];
  private store: preferences.Preferences | undefined = undefined;
  private client: ble.GattClientDevice | undefined = undefined;
  private command: ble.BLECharacteristic | undefined = undefined;
  private actions: RemoteActions | undefined = undefined;
  private epoch: number = 0;
  private foreground: boolean = true;
  private connecting: boolean = false;
  private permissionPending: boolean = false;
  private adapterSubscribed: boolean = false;
  private scanTimer: number = -1;
  private connectionResolve: (() => void) | undefined = undefined;
  private connectionReject: ((error: Error) => void) | undefined = undefined;
  private stepAbort: ((error: Error) => void) | undefined = undefined;
  private pairAbort: (() => void) | undefined = undefined;
  private closing: Promise<void> | undefined = undefined;
  private stateListener: ((event: ble.BLEConnectionChangeState) => void) | undefined = undefined;
  private notifyListener: ((value: ble.BLECharacteristic) => void) | undefined = undefined;

  subscribe(listener: (state: RemoteView) => void): () => void {
    this.listeners.push(listener);
    listener(this.copy());
    return () => { this.listeners = this.listeners.filter(item => item !== listener); };
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, { name: 'sony_remote' });
      this.state.lastId = await this.store.get('lastId', '') as string;
      this.state.lastName = await this.store.get('lastName', '') as string;
      this.emit();
    } catch (error) { this.log('读取上次设备：' + errorText(error as Error)); }
  }

  activate(): void { this.foreground = true; }

  async suspend(): Promise<void> {
    this.foreground = false;
    await this.disconnect();
  }

  async dispose(): Promise<void> {
    await this.suspend();
    if (this.adapterSubscribed) {
      try { access.off('stateChange', this.onAdapterState); } catch (_) {}
      this.adapterSubscribed = false;
    }
    this.listeners = [];
  }

  private onAdapterState = (state: access.BluetoothState): void => {
    if (state === access.BluetoothState.STATE_OFF || state === access.BluetoothState.STATE_TURNING_OFF) {
      this.stopScan();
      this.drop('蓝牙已关闭，请打开后重新连接');
    }
  };

  private async authorize(context: common.UIAbilityContext): Promise<void> {
    if (this.permissionPending) { throw new Error('请先完成权限授权'); }
    if (!canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      throw new Error('当前手表不支持蓝牙接口');
    }
    this.permissionPending = true;
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        throw new Error('请允许蓝牙权限后重试');
      }
      if (!this.foreground) { throw new Error('应用已离开前台'); }
      const state = access.getState();
      if (state !== access.BluetoothState.STATE_ON && state !== access.BluetoothState.STATE_BLE_ON) {
        throw new Error('请先在手表设置中打开蓝牙');
      }
      if (!this.adapterSubscribed) {
        access.on('stateChange', this.onAdapterState);
        this.adapterSubscribed = true;
      }
    } catch (error) {
      throw new Error(errorText(error as Error));
    } finally { this.permissionPending = false; }
  }

  async scan(context: common.UIAbilityContext): Promise<void> {
    if (this.connecting || this.closing || this.state.ready || this.permissionPending) { return; }
    let scanStep: string = '蓝牙授权';
    try {
      await this.authorize(context);
      this.stopScan();
      this.state.devices = [];
      this.state.scanning = true;
      this.state.phase = 'scanning';
      this.state.message = '正在搜索，请让相机进入配对';
      scanStep = '注册扫描监听';
      ble.on('BLEDeviceFind', this.onScan);
      // Use explicit Sony camera filters and scan options for the WATCH 5 scanner.
      const filter: ble.ScanFilter = {
        manufactureId: 0x012d,
        manufactureData: new Uint8Array([0x03, 0x00]).buffer as ArrayBuffer,
        manufactureDataMask: new Uint8Array([0xff, 0xff]).buffer as ArrayBuffer
      };
      const scanOptions: ble.ScanOptions = { interval: 500,
        dutyMode: ble.ScanDuty.SCAN_MODE_BALANCED,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE };
      scanStep = '启动相机扫描';
      ble.startBLEScan([filter], scanOptions);
      this.log('相机扫描已启动');
      this.scanTimer = setTimeout(() => this.stopScan(), 15000);
      this.emit();
    } catch (error) {
      this.stopScan();
      this.state.message = errorText(error as Error);
      this.log(scanStep + '：' + this.state.message);
      this.emit();
    }
  }

  stopScan(): void {
    clearTimeout(this.scanTimer);
    this.scanTimer = -1;
    if (this.state.scanning) {
      try { ble.stopBLEScan(); } catch (_) {}
      try { ble.off('BLEDeviceFind', this.onScan); } catch (_) {}
      this.state.scanning = false;
      this.state.phase = 'idle';
      this.state.message = this.state.devices.length > 0 ? '请选择相机连接' : '未找到相机，请检查配对设置';
      this.emit();
    }
  }

  private onScan = (results: ble.ScanResult[]): void => {
    if (!this.foreground || !this.state.scanning) { return; }
    for (const result of results) {
      let advertisement = parseAdvertisement(new Uint8Array(result.data));
      // On newer SDKs the decoded manufacturer value excludes the two-byte company ID.
      const manufacturer = result.manufacturerDataMap?.get(0x012d);
      if (!advertisement.isSonyCamera && manufacturer) {
        const prefixed = new Uint8Array(manufacturer.length + 2);
        prefixed.set([0x2d, 0x01]);
        prefixed.set(manufacturer, 2);
        advertisement = parseManufacturer(prefixed);
      }
      const name = result.deviceName || advertisement.localName;
      if (!advertisement.isSonyCamera && !name.startsWith('ILCE-') && !name.startsWith('DSC-')) { continue; }
      if (!this.state.devices.some(item => item.id === result.deviceId)) {
        this.log('发现相机：' + (name || 'Sony 相机'));
      }
      const device = new CameraDevice();
      device.id = result.deviceId;
      device.name = name || 'Sony 相机';
      device.rssi = result.rssi;
      device.pairing = advertisement.pairing;
      this.state.devices = this.state.devices.filter(item => item.id !== device.id).concat([device]);
    }
    this.state.devices.sort((a: CameraDevice, b: CameraDevice): number => b.rssi - a.rssi);
    this.emit();
  };

  async reconnect(context: common.UIAbilityContext): Promise<void> {
    if (!this.state.lastId) { return; }
    const device = new CameraDevice();
    device.id = this.state.lastId;
    device.name = this.state.lastName || 'Sony 相机';
    await this.connect(context, device);
  }

  async connect(context: common.UIAbilityContext, device: CameraDevice): Promise<void> {
    if (this.connecting || this.closing || this.state.busy || this.state.ready || this.permissionPending) { return; }
    this.connecting = true;
    let epoch = this.epoch;
    try {
      await this.authorize(context);
      this.stopScan();
      this.drop('正在连接');
      epoch = this.epoch;
      this.state.cameraName = device.name;
      this.state.phase = 'connecting';
      this.state.message = '正在连接 ' + device.name;
      this.emit();
      const client = ble.createGattClientDevice(device.id);
      this.client = client;
      this.stateListener = (event: ble.BLEConnectionChangeState): void => {
        if (epoch !== this.epoch) { return; }
        if (event.state === constant.ProfileConnectionState.STATE_CONNECTED) {
          const resolve = this.connectionResolve;
          if (resolve) { resolve(); }
        } else if (event.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
          this.drop('相机已断开，请重新连接');
        }
      };
      client.on('BLEConnectionStateChange', this.stateListener);
      await this.waitConnected(client);
      this.checkEpoch(epoch);
      if (connection.getPairState(device.id) !== connection.BondState.BOND_STATE_BONDED) {
        this.state.phase = 'pairing';
        this.state.message = '请在相机和手表上确认配对';
        this.emit();
        await this.waitPaired(device.id);
      }
      this.checkEpoch(epoch);
      await pause(200);
      this.checkEpoch(epoch);
      this.state.phase = 'discovering';
      this.state.message = '正在准备遥控';
      this.emit();
      const services = await this.step(client.getServices(), 10000, '读取相机服务超时');
      this.checkEpoch(epoch);
      const service = services.find(item => item.serviceUuid.toLowerCase() === REMOTE_SERVICE);
      const command = service?.characteristics.find(item =>
        item.characteristicUuid.toLowerCase() === COMMAND_CHARACTERISTIC);
      const status = service?.characteristics.find(item =>
        item.characteristicUuid.toLowerCase() === STATUS_CHARACTERISTIC);
      if (!command || !status) {
        throw new Error('未找到遥控服务；请开启相机“蓝牙遥控”');
      }
      this.command = command;
      const transport = new BleCommandTransport((bytes: Uint8Array): Promise<void> => this.write(bytes, epoch));
      this.actions = new RemoteActions(transport);
      this.notifyListener = (value: ble.BLECharacteristic): void => {
        if (epoch !== this.epoch || value.characteristicUuid.toLowerCase() !== STATUS_CHARACTERISTIC) { return; }
        const bytes = new Uint8Array(value.characteristicValue);
        this.actions?.notify(bytes);
        const event = parseNotification(bytes);
        if (event.kind === 'focus') { this.state.focusReady = event.active; }
        if (event.kind === 'recording') {
          this.state.recordingKnown = true;
          this.state.recording = event.active;
          this.state.message = event.active ? '录像中' : '录像已停止';
        }
        if (event.kind) { this.log(event.kind + (event.active ? ': active' : ': idle')); }
        this.emit();
      };
      client.on('BLECharacteristicChange', this.notifyListener);
      await this.step(client.setCharacteristicChangeNotification(status, true), 5000, '订阅相机状态超时');
      this.checkEpoch(epoch);
      // Clear any button state left by an earlier interrupted connection.
      await this.actions.release();
      this.checkEpoch(epoch);
      this.state.ready = true;
      this.state.phase = 'ready';
      this.state.message = '已连接，可以拍照';
      this.state.lastId = device.id;
      this.state.lastName = device.name;
      this.log('遥控就绪：' + device.name);
      this.emit();
      await this.remember(device);
    } catch (error) {
      if (epoch === this.epoch && this.foreground && this.state.phase !== 'closing') {
        this.drop(errorText(error as Error));
      }
    } finally {
      this.connecting = false;
      this.emit();
    }
  }

  private waitConnected(client: ble.GattClientDevice): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let timer: number = -1;
      const finish = (error?: Error): void => {
        clearTimeout(timer);
        this.connectionResolve = undefined;
        this.connectionReject = undefined;
        if (error) { reject(error); } else { resolve(); }
      };
      this.connectionResolve = (): void => finish();
      this.connectionReject = (error: Error): void => finish(error);
      timer = setTimeout(() => finish(new Error('连接超时，请确认相机已开机')), 10000);
      try { client.connect(); } catch (error) { finish(error as Error); }
    });
  }

  private waitPaired(id: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let timer: number = -1;
      let settled: boolean = false;
      const finish = (error?: Error): void => {
        if (settled) { return; }
        settled = true;
        clearTimeout(timer);
        try { connection.off('bondStateChange', listener); } catch (_) {}
        this.pairAbort = undefined;
        if (error) { reject(error); } else { resolve(); }
      };
      const listener = (event: connection.BondStateParam): void => {
        if (event.deviceId !== id) { return; }
        if (event.state === connection.BondState.BOND_STATE_BONDED) { finish(); }
        else if (event.state === connection.BondState.BOND_STATE_INVALID) {
          finish(new Error('配对未完成，请在相机重新进入配对'));
        }
      };
      this.pairAbort = (): void => finish(new Error('连接已取消'));
      timer = setTimeout(() => finish(new Error('配对超时，请重新进入配对')), 45000);
      try {
        connection.on('bondStateChange', listener);
        connection.pairDevice(id).then(() => {
          if (connection.getPairState(id) === connection.BondState.BOND_STATE_BONDED) { finish(); }
        }).catch((error: BusinessError) => finish(error as Error));
      } catch (error) { finish(error as Error); }
    });
  }

  private step<T>(work: Promise<T>, timeout: number, message: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let settled: boolean = false;
      let timer: number = -1;
      const finish = (value?: T, error?: Error): void => {
        if (settled) { return; }
        settled = true;
        clearTimeout(timer);
        this.stepAbort = undefined;
        if (error) { reject(error); } else { resolve(value as T); }
      };
      this.stepAbort = (error: Error): void => finish(undefined, error);
      timer = setTimeout(() => finish(undefined, new Error(message)), timeout);
      work.then((value: T) => finish(value)).catch((error: Error) => finish(undefined, error));
    });
  }

  private checkEpoch(epoch: number): void {
    if (epoch !== this.epoch || !this.foreground || this.state.phase === 'closing') {
      throw new Error('连接已取消');
    }
  }

  private async write(bytes: Uint8Array, epoch: number): Promise<void> {
    const client = this.client;
    const original = this.command;
    if (!client || !original || epoch !== this.epoch) { throw new Error('相机未连接'); }
    const value: ble.BLECharacteristic = {
      serviceUuid: original.serviceUuid,
      characteristicUuid: original.characteristicUuid,
      characteristicValue: bytes.buffer as ArrayBuffer,
      descriptors: original.descriptors,
      characteristicValueHandle: original.characteristicValueHandle
    };
    try {
      await deadline(client.writeCharacteristicValue(value, ble.GattWriteType.WRITE), 2000, '蓝牙写入超时');
      if (epoch !== this.epoch) { throw new Error('连接已中断'); }
    } catch (error) {
      if (epoch === this.epoch) { this.drop('通信中断：' + errorText(error as Error)); }
      throw error as Error;
    }
  }

  async capture(autoFocus: boolean, seconds: number): Promise<void> {
    const actions = this.actions;
    if (!this.foreground || !this.state.ready || this.state.busy || !actions) { return; }
    const epoch = this.epoch;
    this.state.busy = true;
    this.state.message = seconds > 0 ? '倒计时中，可点快门取消' : (autoFocus ? '对焦并拍照…' : '正在拍照…');
    this.emit();
    try {
      await actions.capture(autoFocus, seconds, (remaining: number): void => {
        if (epoch === this.epoch) { this.state.countdown = remaining; this.emit(); }
      });
      if (epoch === this.epoch) { this.state.message = '快门已响应'; }
    } catch (error) {
      if (epoch === this.epoch) { this.state.message = errorText(error as Error); this.log(this.state.message); }
    } finally {
      if (epoch === this.epoch) { this.state.busy = false; this.state.countdown = 0; this.emit(); }
    }
  }

  async focus(): Promise<void> {
    const actions = this.actions;
    if (!this.foreground || !this.state.ready || this.state.busy || !actions) { return; }
    const epoch = this.epoch;
    this.state.busy = true;
    this.state.message = '正在对焦…';
    this.emit();
    try {
      await actions.focus();
      if (epoch === this.epoch) { this.state.message = '已对焦，半按已释放'; }
    } catch (error) {
      if (epoch === this.epoch) { this.state.message = errorText(error as Error); }
    } finally {
      if (epoch === this.epoch) { this.state.busy = false; this.emit(); }
    }
  }

  async record(): Promise<void> {
    const actions = this.actions;
    if (!this.foreground || !this.state.ready || this.state.busy || !actions) { return; }
    const epoch = this.epoch;
    this.state.busy = true;
    this.state.message = '正在发送录像键';
    this.emit();
    try {
      await actions.record();
      if (epoch === this.epoch) { this.state.message = '录像键已发送，请查看相机状态'; }
    } catch (error) {
      if (epoch === this.epoch) { this.state.message = errorText(error as Error); }
    } finally {
      if (epoch === this.epoch) { this.state.busy = false; this.emit(); }
    }
  }

  cancel(): void { this.actions?.cancel(); }

  disconnect(): Promise<void> {
    if (this.closing) { return this.closing; }
    const work = this.disconnectInner().finally(() => { this.closing = undefined; });
    this.closing = work;
    return work;
  }

  private async disconnectInner(): Promise<void> {
    this.stopScan();
    this.state.phase = 'closing';
    const reject = this.connectionReject;
    if (reject) { reject(new Error('连接已取消')); }
    const abort = this.pairAbort;
    if (abort) { abort(); }
    this.emit();
    try { await this.actions?.stop(); } catch (error) { this.log(errorText(error as Error)); }
    this.drop('连接已断开');
  }

  private drop(message: string): void {
    this.epoch++;
    const abortStep = this.stepAbort;
    if (abortStep) { abortStep(new Error(message)); }
    const reject = this.connectionReject;
    if (reject) { reject(new Error(message)); }
    const abort = this.pairAbort;
    if (abort) { abort(); }
    this.actions?.cancel();
    this.actions = undefined;
    const client = this.client;
    this.client = undefined;
    this.command = undefined;
    if (client) {
      try { if (this.stateListener) { client.off('BLEConnectionStateChange', this.stateListener); } } catch (_) {}
      try { if (this.notifyListener) { client.off('BLECharacteristicChange', this.notifyListener); } } catch (_) {}
      try { client.disconnect(); } catch (_) {}
      try { client.close(); } catch (_) {}
    }
    this.stateListener = undefined;
    this.notifyListener = undefined;
    this.state.ready = false;
    this.state.busy = false;
    this.state.countdown = 0;
    this.state.recordingKnown = false;
    this.state.recording = false;
    this.state.focusReady = false;
    this.state.phase = 'idle';
    this.state.message = message;
    this.log(message);
    this.emit();
  }

  private async remember(device: CameraDevice): Promise<void> {
    try {
      await this.store?.put('lastId', device.id);
      await this.store?.put('lastName', device.name);
      await this.store?.flush();
    } catch (error) { this.log('设备记录未保存：' + errorText(error as Error)); }
  }

  private log(message: string): void {
    const time = new Date().toLocaleTimeString();
    this.state.logs = [time + ' ' + message].concat(this.state.logs).slice(0, 20);
    hilog.info(0x0000, 'SonyRemote', '%{public}s', message);
  }

  private copy(): RemoteView {
    const copy = new RemoteView();
    copy.phase = this.state.phase;
    copy.ready = this.state.ready;
    copy.scanning = this.state.scanning;
    copy.busy = this.state.busy;
    copy.countdown = this.state.countdown;
    copy.cameraName = this.state.cameraName;
    copy.message = this.state.message;
    copy.lastId = this.state.lastId;
    copy.lastName = this.state.lastName;
    copy.recordingKnown = this.state.recordingKnown;
    copy.recording = this.state.recording;
    copy.focusReady = this.state.focusReady;
    copy.devices = this.state.devices.slice();
    copy.logs = this.state.logs.slice();
    return copy;
  }

  private emit(): void {
    for (const listener of this.listeners) { listener(this.copy()); }
  }
}

export const remote: SonyRemote = new SonyRemote();
