import { commandBytes, parseNotification, RemoteCommand } from './SonyProtocol';

export interface CommandTransport {
  write(bytes: Uint8Array): Promise<void>;
}
export class CaptureResult {
  confirmed: boolean = false;
}
export class ActionTiming {
  focusTimeout: number = 5000;
  shutterTimeout: number = 2500;
  writeTimeout: number = 3000;
  pollInterval: number = 25;
  focusPreview: number = 500;
}
export function pause(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve) => { setTimeout(() => resolve(), milliseconds); });
}

// Pure state machine, shared by the device app and host-side protocol tests.
export class RemoteActions {
  private transport: CommandTransport;
  private timing: ActionTiming;
  private generation: number = 0;
  private operation: Promise<CaptureResult> | undefined = undefined;
  private focusEvents: number = 0;
  private shutterEvents: number = 0;

  constructor(transport: CommandTransport, timing: ActionTiming = new ActionTiming()) {
    this.transport = transport;
    this.timing = timing;
  }
  notify(bytes: Uint8Array): void {
    const state = parseNotification(bytes);
    if (state.kind === 'focus' && state.active) { this.focusEvents++; }
    if (state.kind === 'shutter' && state.active) { this.shutterEvents++; }
  }
  cancel(): void { this.generation++; }

  capture(autoFocus: boolean, seconds: number, countdown: (remaining: number) => void): Promise<CaptureResult> {
    return this.run((token: number): Promise<CaptureResult> => this.captureInner(token, autoFocus, seconds, countdown));
  }
  focus(): Promise<CaptureResult> {
    return this.run(async (token: number): Promise<CaptureResult> => {
      const baseline = this.focusEvents;
      try {
        await this.send(RemoteCommand.FocusDown);
        await this.waitForEvent(token, 'focus', baseline, this.timing.focusTimeout);
        await this.sleep(token, this.timing.focusPreview);
        const result = new CaptureResult();
        result.confirmed = true;
        return result;
      } finally { await this.release(); }
    });
  }
  record(): Promise<CaptureResult> {
    return this.run(async (token: number): Promise<CaptureResult> => {
      // A7M3 needs a full press/release cycle; release-only was ineffective on device.
      try {
        this.check(token);
        await this.send(RemoteCommand.RecordDown);
        await this.sleep(token, 100);
        return new CaptureResult();
      } finally { await this.send(RemoteCommand.RecordUp); }
    });
  }
  async stop(): Promise<void> {
    this.cancel();
    const current = this.operation;
    if (current) {
      try { await current; } catch (_) { /* Action caller receives the failure. */ }
    }
    await this.release();
  }
  async release(): Promise<void> {
    let failure: Error | undefined = undefined;
    try { await this.send(RemoteCommand.ShutterUp); } catch (error) { failure = error as Error; }
    try { await this.send(RemoteCommand.FocusUp); } catch (error) { failure = error as Error; }
    if (failure) { throw failure; }
  }
  private run(task: (token: number) => Promise<CaptureResult>): Promise<CaptureResult> {
    if (this.operation) { return Promise.reject(new Error('上一项操作尚未结束')); }
    const token = ++this.generation;
    const running = task(token).finally(() => {
      if (this.operation === running) { this.operation = undefined; }
    });
    this.operation = running;
    return running;
  }
  private async captureInner(token: number, autoFocus: boolean, seconds: number,
    countdown: (remaining: number) => void): Promise<CaptureResult> {
    try {
      for (let remaining = seconds; remaining > 0; remaining--) {
        countdown(remaining);
        await this.sleep(token, 1000);
      }
      countdown(0);
      this.check(token);
      const focusBaseline = this.focusEvents;
      await this.send(RemoteCommand.FocusDown);
      if (autoFocus) {
        await this.waitForEvent(token, 'focus', focusBaseline, this.timing.focusTimeout);
      }
      this.check(token);
      const shutterBaseline = this.shutterEvents;
      await this.send(RemoteCommand.ShutterDown);
      await this.waitForEvent(token, 'shutter', shutterBaseline, this.timing.shutterTimeout);
      const result = new CaptureResult();
      result.confirmed = true;
      return result;
    } finally {
      countdown(0);
      await this.release();
    }
  }
  private async waitForEvent(token: number, kind: string, baseline: number, timeout: number): Promise<void> {
    const deadline = Date.now() + timeout;
    while (true) {
      this.check(token);
      const count = kind === 'focus' ? this.focusEvents : this.shutterEvents;
      if (count > baseline) { return; }
      if (Date.now() >= deadline) {
        throw new Error(kind === 'focus' ? '对焦超时；请检查 AF 设置，或改用手动对焦' : '未收到快门反馈，请检查相机');
      }
      await pause(this.timing.pollInterval);
    }
  }
  private async sleep(token: number, milliseconds: number): Promise<void> {
    const deadline = Date.now() + milliseconds;
    while (Date.now() < deadline) {
      this.check(token);
      await pause(Math.min(this.timing.pollInterval, deadline - Date.now()));
    }
    this.check(token);
  }
  private check(token: number): void {
    if (token !== this.generation) { throw new Error('操作已取消'); }
  }
  private async send(command: RemoteCommand): Promise<void> {
    let timer: number = -1;
    try {
      await Promise.race<void>([
        this.transport.write(commandBytes(command)),
        new Promise<void>((_, reject) => {
          timer = setTimeout(() => reject(new Error('蓝牙写入超时')), this.timing.writeTimeout);
        })
      ]);
    } finally { clearTimeout(timer); }
  }
}
