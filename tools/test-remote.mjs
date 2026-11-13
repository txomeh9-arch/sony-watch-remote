import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const deveco = process.env.DEVECO_ROOT;
if (!deveco) throw new Error('Set DEVECO_ROOT to your DevEco Studio installation directory.');
const ts = require(path.join(deveco, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
const sourceRoot = path.join(root, 'entry/src/main/ets/remote');

function loader(kits = {}, capability = () => true) {
  const cache = new Map();
  function load(name) {
    if (cache.has(name)) return cache.get(name).exports;
    const filename = path.join(sourceRoot, name + '.ets');
    const input = fs.readFileSync(filename, 'utf8');
    const result = ts.transpileModule(input, {
      fileName: name + '.ts',
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    });
    const module = { exports: {} };
    cache.set(name, module);
    const localRequire = id => {
      if (id.startsWith('./')) return load(id.slice(2));
      if (kits[id]) return kits[id];
      throw new Error('Unexpected platform import: ' + id);
    };
    new Function('require', 'module', 'exports', 'canIUse', result.outputText)(
      localRequire, module, module.exports, capability);
    return module.exports;
  }
  return load;
}

const load = loader();
const protocol = load('SonyProtocol');
const { RemoteActions, ActionTiming } = load('RemoteActions');
const sonyManufacturer = [0x2d, 0x01, 0x03, 0x00, 0x64, 0x00, 0x45, 0x31, 0x22, 0xef, 0x00];
const ad = payload => new Uint8Array([payload.length + 1, 0xff, ...payload]);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function rig(options = {}) {
  const writes = [];
  let actions;
  const timing = new ActionTiming();
  timing.focusTimeout = 25;
  timing.shutterTimeout = 25;
  timing.writeTimeout = 25;
  timing.pollInterval = 1;
  timing.focusPreview = 1;
  const transport = {
    async write(bytes) {
      writes.push(Array.from(bytes));
      const code = bytes[1];
      if (options.fail === code) throw new Error('simulated write failure');
      if (options.hang === code) return new Promise(() => {});
      if (options.onWrite) options.onWrite(code, actions);
      if (code === 7 && options.focus !== false) {
        queueMicrotask(() => actions.notify(new Uint8Array([2, 0x3f, 0x20])));
      }
      if (code === 9 && options.shutter !== false) {
        queueMicrotask(() => actions.notify(new Uint8Array([2, 0xa0, 0x20])));
      }
    }
  };
  actions = new RemoteActions(transport, timing);
  return { actions, writes };
}

test('Sony manufacturer data, pairing status and AD local name are decoded', () => {
  const info = protocol.parseAdvertisement(new Uint8Array([
    2, 1, 6, ...ad(sonyManufacturer), 10, 9, ...Buffer.from('ILCE-7M3X')
  ]));
  assert.equal(info.isSonyCamera, true);
  assert.equal(info.pairing, true);
  assert.equal(info.localName, 'ILCE-7M3X');
  const closed = [...sonyManufacturer];
  closed[9] = 0xaf;
  assert.equal(protocol.parseManufacturer(new Uint8Array(closed)).pairing, false);
});

test('malformed, non-camera and other-vendor advertisements are rejected', () => {
  for (const payload of [[], [0x2d], [0x2d, 1, 4, 0], [0x2e, 1, 3, 0]]) {
    assert.equal(protocol.parseManufacturer(new Uint8Array(payload)).isSonyCamera, false);
  }
  assert.equal(protocol.parseAdvertisement(new Uint8Array([40, 0xff, ...sonyManufacturer])).isSonyCamera, false);
});

test('only valid three-byte camera notifications are interpreted', () => {
  assert.equal(protocol.parseNotification(new Uint8Array([2, 0xd5, 0x20])).kind, 'recording');
  assert.equal(protocol.parseNotification(new Uint8Array([2, 0x3f, 0x40])).active, false);
  for (const bytes of [[], [2, 0xa0], [1, 0xa0, 0x20], [2, 0xff, 0x20]]) {
    assert.equal(protocol.parseNotification(new Uint8Array(bytes)).kind, '');
  }
});

test('AF capture waits for fresh focus and shutter feedback, then releases both states', async () => {
  const { actions, writes } = rig();
  assert.equal((await actions.capture(true, 0, () => {})).confirmed, true);
  assert.deepEqual(writes, [[1, 7], [1, 9], [1, 8], [1, 6]]);
});

test('MF capture does not require autofocus feedback', async () => {
  const { actions, writes } = rig({ focus: false });
  assert.equal((await actions.capture(false, 0, () => {})).confirmed, true);
  assert.deepEqual(writes, [[1, 7], [1, 9], [1, 8], [1, 6]]);
});

test('AF timeout never presses the shutter and still releases both states', async () => {
  const { actions, writes } = rig({ focus: false });
  await assert.rejects(actions.capture(true, 0, () => {}), /对焦超时/);
  assert.deepEqual(writes, [[1, 7], [1, 8], [1, 6]]);
});

test('previous focus feedback cannot satisfy a new capture', async () => {
  const { actions, writes } = rig({ focus: false });
  actions.notify(new Uint8Array([2, 0x3f, 0x20]));
  await assert.rejects(actions.capture(true, 0, () => {}), /对焦超时/);
  assert.equal(writes.some(bytes => bytes[1] === 9), false);
});

test('missing shutter feedback fails without retrying the shutter', async () => {
  const { actions, writes } = rig({ shutter: false });
  await assert.rejects(actions.capture(true, 0, () => {}), /快门反馈/);
  assert.equal(writes.filter(bytes => bytes[1] === 9).length, 1);
  assert.deepEqual(writes.slice(-2), [[1, 8], [1, 6]]);
});

test('countdown cancellation sends no press command', async () => {
  const { actions, writes } = rig();
  await assert.rejects(actions.capture(true, 3, n => { if (n === 3) actions.cancel(); }), /已取消/);
  assert.deepEqual(writes, [[1, 8], [1, 6]]);
});

test('cancelling during autofocus releases and does not take a picture', async () => {
  const { actions, writes } = rig({ focus: false, onWrite: (code, engine) => {
    if (code === 7) setTimeout(() => engine.cancel(), 1);
  } });
  await assert.rejects(actions.capture(true, 0, () => {}), /已取消/);
  assert.deepEqual(writes, [[1, 7], [1, 8], [1, 6]]);
});

test('concurrent actions are rejected instead of interleaving commands', async () => {
  const { actions, writes } = rig({ focus: false });
  const first = actions.capture(true, 0, () => {});
  await assert.rejects(actions.focus(), /尚未结束/);
  await assert.rejects(first, /对焦超时/);
  assert.deepEqual(writes, [[1, 7], [1, 8], [1, 6]]);
});

test('write failure after half-press still attempts the two release commands', async () => {
  const { actions, writes } = rig({ fail: 9 });
  await assert.rejects(actions.capture(true, 0, () => {}), /write failure/);
  assert.deepEqual(writes, [[1, 7], [1, 9], [1, 8], [1, 6]]);
});

test('failed full-release does not suppress half-release', async () => {
  const { actions, writes } = rig({ fail: 8 });
  await assert.rejects(actions.capture(true, 0, () => {}), /write failure/);
  assert.deepEqual(writes.slice(-2), [[1, 8], [1, 6]]);
});

test('hung GATT writes have a deadline and a cleanup path', async () => {
  const { actions, writes } = rig({ hang: 7 });
  await assert.rejects(actions.capture(true, 0, () => {}), /写入超时/);
  assert.deepEqual(writes, [[1, 7], [1, 8], [1, 6]]);
});

test('video button is released when the operation is cancelled', async () => {
  const { actions, writes } = rig({ onWrite: (code, engine) => {
    if (code === 0x0f) engine.cancel();
  } });
  await assert.rejects(actions.record(), /已取消/);
  assert.deepEqual(writes, [[1, 0x0f], [1, 0x0e]]);
});

test('a failed movie press attempts release without retrying the press', async () => {
  const { actions, writes } = rig({ fail: 0x0f });
  await assert.rejects(actions.record(), /write failure/);
  assert.deepEqual(writes, [[1, 0x0f], [1, 0x0e]]);
});

test('stop waits for cancellation and finishes in a neutral button state', async () => {
  const { actions, writes } = rig({ focus: false });
  const operation = actions.capture(true, 0, () => {});
  const observed = operation.catch(() => {});
  await actions.stop();
  await observed;
  assert.equal(writes.some(bytes => bytes[1] === 9), false);
  assert.deepEqual(writes.slice(-2), [[1, 8], [1, 6]]);
});

async function until(predicate, timeout = 1200) {
  const end = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() > end) throw new Error('condition timed out');
    await sleep(2);
  }
}

function platformRig(options = {}) {
  const bleEvents = new Map();
  const bondEvents = new Set();
  const adapterEvents = new Set();
  const clients = [];
  const memory = new Map();
  let bonded = options.bonded !== false;
  let discoveryResolve;
  let deferred = false;
  const command = { serviceUuid: protocol.REMOTE_SERVICE, characteristicUuid: protocol.COMMAND_CHARACTERISTIC,
    characteristicValue: new ArrayBuffer(0), descriptors: [] };
  const status = { ...command, characteristicUuid: protocol.STATUS_CHARACTERISTIC };
  const services = [{ serviceUuid: protocol.REMOTE_SERVICE, isPrimary: true, characteristics: [command, status] }];

  class FakeGatt {
    events = new Map();
    writes = [];
    closed = false;
    on(name, callback) {
      if (!this.events.has(name)) this.events.set(name, new Set());
      this.events.get(name).add(callback);
    }
    off(name, callback) { this.events.get(name)?.delete(callback); }
    emit(name, data) { for (const callback of this.events.get(name) || []) callback(data); }
    connect() { queueMicrotask(() => this.emit('BLEConnectionStateChange', { deviceId: 'camera', state: 2 })); }
    disconnect() { this.emit('BLEConnectionStateChange', { deviceId: 'camera', state: 0 }); }
    close() { this.closed = true; }
    async getServices() {
      if (options.deferDiscoveryOnce && !deferred) {
        deferred = true;
        return new Promise(resolve => { discoveryResolve = resolve; });
      }
      return services;
    }
    async setCharacteristicChangeNotification() {}
    async writeCharacteristicValue(value) {
      const bytes = [...new Uint8Array(value.characteristicValue)];
      this.writes.push(bytes);
      if (bytes[1] === options.failCommand) throw new Error('mock transport disconnected');
      const code = bytes[1] === 7 ? 0x3f : bytes[1] === 9 ? 0xa0 : 0;
      if (code) {
        queueMicrotask(() => this.emit('BLECharacteristicChange', {
          ...status, characteristicValue: new Uint8Array([2, code, 0x20]).buffer
        }));
      }
    }
  }
  const connectivity = {
    access: {
      BluetoothState: { STATE_ON: 2, STATE_OFF: 0, STATE_TURNING_OFF: 3, STATE_BLE_ON: 5 },
      getState: () => 2,
      on: (_, callback) => adapterEvents.add(callback),
      off: (_, callback) => adapterEvents.delete(callback)
    },
    ble: {
      ScanDuty: { SCAN_MODE_BALANCED: 1 }, MatchMode: { MATCH_MODE_AGGRESSIVE: 1 },
      GattWriteType: { WRITE: 1 },
      on: (name, callback) => bleEvents.set(name, callback),
      off: (name, callback) => { if (bleEvents.get(name) === callback) bleEvents.delete(name); },
      startBLEScan(filters, scanOptions) {
        if (!filters.length || !Number.isFinite(scanOptions.interval)) {
          throw Object.assign(new Error('Invalid scan parameters'), { code: 401 });
        }
        assert.equal(filters[0].manufactureId, 0x012d);
        assert.deepEqual([...new Uint8Array(filters[0].manufactureData)], [3, 0]);
        if (options.scanError) throw Object.assign(new Error('scan failed'), { code: 401 });
      }, stopBLEScan() {},
      createGattClientDevice() { const client = new FakeGatt(); clients.push(client); return client; }
    },
    constant: { ProfileConnectionState: { STATE_CONNECTED: 2, STATE_DISCONNECTED: 0 } },
    connection: {
      BondState: { BOND_STATE_BONDED: 2, BOND_STATE_INVALID: 0 },
      getPairState: () => bonded ? 2 : 0,
      on: (_, callback) => bondEvents.add(callback),
      off: (_, callback) => bondEvents.delete(callback),
      async pairDevice() {
        if (options.pendingPair) return new Promise(() => {});
        bonded = true;
        for (const callback of bondEvents) callback({ deviceId: 'camera', state: 2 });
      }
    }
  };
  const load = loader({
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({
      requestPermissionsFromUser: async () => ({ authResults: [options.denyPermission ? -1 : 0] })
    }) } },
    '@kit.ConnectivityKit': connectivity,
    '@kit.ArkData': { preferences: { getPreferences: async () => ({
      get: async (key, fallback) => memory.get(key) ?? fallback,
      put: async (key, value) => { memory.set(key, value); }, flush: async () => {}
    }) } },
    '@kit.BasicServicesKit': {},
    '@kit.PerformanceAnalysisKit': { hilog: { info() {} } }
  });
  const { SonyRemote, CameraDevice } = load('SonyRemote');
  const remote = new SonyRemote();
  let view;
  remote.subscribe(value => { view = value; });
  const device = new CameraDevice();
  device.id = 'camera';
  device.name = 'ILCE-7M3';
  return { remote, device, clients, bondEvents, bleEvents, adapterEvents, memory,
    get view() { return view; },
    finishDiscovery: () => discoveryResolve?.(services),
    scanResult: result => bleEvents.get('BLEDeviceFind')?.([result])
  };
}

test('permission rejection starts no scan and reports a usable message', async () => {
  const rig = platformRig({ denyPermission: true });
  try {
    await rig.remote.scan({});
    assert.equal(rig.view.scanning, false);
    assert.match(rig.view.message, /权限/);
    assert.equal(rig.bleEvents.size, 0);
  } finally { await rig.remote.dispose(); }
});

test('scan filters unrelated BLE devices and stops its callback on cancellation', async () => {
  const rig = platformRig();
  try {
    await rig.remote.scan({});
    rig.scanResult({ deviceId: 'other', deviceName: 'headphones', rssi: -40, data: ad([1, 2, 3]).buffer });
    assert.equal(rig.view.devices.length, 0);
    rig.scanResult({ deviceId: 'camera', deviceName: 'ILCE-7M3', rssi: -50, data: ad(sonyManufacturer).buffer });
    assert.equal(rig.view.devices[0].id, 'camera');
    rig.remote.stopScan();
    assert.equal(rig.bleEvents.size, 0);
  } finally { await rig.remote.dispose(); }
});

test('connection subscribes, clears old presses, captures and remembers the camera', async () => {
  const rig = platformRig();
  try {
    await rig.remote.initialize({});
    await rig.remote.connect({}, rig.device);
    assert.equal(rig.view.ready, true);
    assert.deepEqual(rig.clients[0].writes, [[1, 8], [1, 6]]);
    assert.equal(rig.memory.get('lastId'), 'camera');
    await rig.remote.capture(true, 0);
    assert.equal(rig.view.message, '快门已响应');
    assert.deepEqual(rig.clients[0].writes.slice(-4), [[1, 7], [1, 9], [1, 8], [1, 6]]);
  } finally {
    await rig.remote.dispose();
    assert.equal(rig.clients[0].closed, true);
  }
});

test('cancelling pairing removes the listener and cannot mark the camera ready later', async () => {
  const rig = platformRig({ bonded: false, pendingPair: true });
  try {
    const connecting = rig.remote.connect({}, rig.device);
    await until(() => rig.view.phase === 'pairing');
    await rig.remote.disconnect();
    await connecting;
    assert.equal(rig.bondEvents.size, 0);
    assert.equal(rig.view.ready, false);
    assert.equal(rig.clients[0].closed, true);
  } finally { await rig.remote.dispose(); }
});

test('discovery cancellation permits reconnect and ignores the late old result', async () => {
  const rig = platformRig({ deferDiscoveryOnce: true });
  try {
    const first = rig.remote.connect({}, rig.device);
    await until(() => rig.view.phase === 'discovering');
    await rig.remote.disconnect();
    await first;
    await rig.remote.connect({}, rig.device);
    assert.equal(rig.view.ready, true);
    rig.finishDiscovery();
    await sleep(10);
    assert.equal(rig.view.ready, true);
    assert.equal(rig.clients.length, 2);
    assert.equal(rig.clients[0].closed, true);
    assert.equal(rig.clients[1].closed, false);
  } finally { await rig.remote.dispose(); }
});

test('a transport failure disables the remote and never retries the shutter', async () => {
  const rig = platformRig({ failCommand: 9 });
  try {
    await rig.remote.connect({}, rig.device);
    await rig.remote.capture(true, 0);
    assert.equal(rig.view.ready, false);
    assert.match(rig.view.message, /通信中断/);
    assert.equal(rig.clients[0].closed, true);
    assert.equal(rig.clients[0].writes.filter(bytes => bytes[1] === 9).length, 1);
  } finally { await rig.remote.dispose(); }
});

test('decoded manufacturer map is accepted when raw scan data is absent', async () => {
  const rig = platformRig();
  try {
    await rig.remote.scan({});
    rig.scanResult({ deviceId: 'map-camera', deviceName: '', rssi: -60,
      data: new ArrayBuffer(0),
      manufacturerDataMap: new Map([[0x012d, new Uint8Array(sonyManufacturer.slice(2))]]) });
    assert.equal(rig.view.devices[0].id, 'map-camera');
    assert.equal(rig.view.devices[0].pairing, true);
  } finally { await rig.remote.dispose(); }
});

test('returning to the watch face cancels countdown without firing and allows manual reconnect', async () => {
  const rig = platformRig();
  try {
    await rig.remote.connect({}, rig.device);
    const capturing = rig.remote.capture(true, 3);
    await until(() => rig.view.countdown === 3);
    await rig.remote.suspend();
    await capturing;
    assert.equal(rig.clients[0].writes.some(bytes => bytes[1] === 9), false);
    assert.equal(rig.clients[0].closed, true);
    assert.equal(rig.view.ready, false);
    rig.remote.activate();
    await rig.remote.reconnect({});
    assert.equal(rig.view.ready, true);
  } finally { await rig.remote.dispose(); }
});

test('Bluetooth shutdown stops scanning and removes its event callback', async () => {
  const rig = platformRig();
  try {
    await rig.remote.scan({});
    for (const callback of rig.adapterEvents) callback(0);
    assert.equal(rig.view.scanning, false);
    assert.equal(rig.bleEvents.size, 0);
    assert.match(rig.view.message, /蓝牙已关闭/);
  } finally { await rig.remote.dispose(); }
});

test('native scan errors remove the event callback and clear the scanning state', async () => {
  const rig = platformRig({ scanError: true });
  try {
    await rig.remote.scan({});
    assert.equal(rig.view.scanning, false);
    assert.equal(rig.bleEvents.size, 0);
    assert.match(rig.view.message, /401/);
    assert.ok(rig.view.logs.some(line => line.includes('启动相机扫描')));
  } finally { await rig.remote.dispose(); }
});
