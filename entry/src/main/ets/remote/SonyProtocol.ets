// Protocol facts: coral/freemote and Greg Leeds. Original ArkTS implementation.
export const REMOTE_SERVICE: string = '8000ff00-ff00-ffff-ffff-ffffffffffff';
export const COMMAND_CHARACTERISTIC: string = '0000ff01-0000-1000-8000-00805f9b34fb';
export const STATUS_CHARACTERISTIC: string = '0000ff02-0000-1000-8000-00805f9b34fb';

export enum RemoteCommand {
  FocusUp = 0x06, FocusDown = 0x07, ShutterUp = 0x08, ShutterDown = 0x09,
  RecordUp = 0x0e, RecordDown = 0x0f
}

export class Advertisement {
  isSonyCamera: boolean = false;
  pairing: boolean = false;
  localName: string = '';
}

export class CameraNotification {
  kind: string = '';
  active: boolean = false;
}

export function commandBytes(command: RemoteCommand): Uint8Array {
  return new Uint8Array([0x01, command]);
}

// data includes the company ID (2D 01).
export function parseManufacturer(data: Uint8Array): Advertisement {
  const result = new Advertisement();
  if (data.length < 4 || data[0] !== 0x2d || data[1] !== 0x01 ||
    data[2] !== 0x03 || data[3] !== 0x00) {
    return result;
  }
  result.isSonyCamera = true;
  for (let offset = 8; offset + 2 < data.length; offset += 3) {
    if (data[offset] === 0) { break; }
    if (data[offset] === 0x22) {
      result.pairing = (data[offset + 1] & 0x40) !== 0;
    }
  }
  return result;
}

export function parseAdvertisement(bytes: Uint8Array): Advertisement {
  let result = new Advertisement();
  let name: string = '';
  for (let offset = 0; offset < bytes.length;) {
    const length = bytes[offset];
    if (length === 0 || offset + length >= bytes.length) { break; }
    const type = bytes[offset + 1];
    const payload = bytes.slice(offset + 2, offset + length + 1);
    if (type === 0xff) {
      const manufacturer = parseManufacturer(payload);
      if (manufacturer.isSonyCamera) { result = manufacturer; }
    }
    if (type === 0x08 || type === 0x09) {
      let value: string = '';
      for (let index = 0; index < payload.length; index++) {
        if (payload[index] >= 0x20 && payload[index] < 0x7f) {
          value += String.fromCharCode(payload[index]);
        }
      }
      if (type === 0x09 || name.length === 0) { name = value; }
    }
    offset += length + 1;
  }
  result.localName = name;
  return result;
}

export function parseNotification(bytes: Uint8Array): CameraNotification {
  const result = new CameraNotification();
  if (bytes.length !== 3 || bytes[0] !== 0x02) { return result; }
  if (bytes[1] === 0x3f) { result.kind = 'focus'; }
  else if (bytes[1] === 0xa0) { result.kind = 'shutter'; }
  else if (bytes[1] === 0xd5) { result.kind = 'recording'; }
  result.active = bytes[2] === 0x20;
  return result;
}
