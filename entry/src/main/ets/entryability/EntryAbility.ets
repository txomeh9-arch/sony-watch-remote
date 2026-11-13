import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { remote } from '../remote/SonyRemote';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index', (error) => {
      if (error.code) { hilog.error(0, 'SonyRemote', 'loadContent: %{public}s', error.message); }
    });
  }
  onForeground(): void { remote.activate(); }
  onBackground(): void {
    remote.suspend().catch((error: Error) => hilog.error(0, 'SonyRemote', '%{public}s', error.message));
  }
  onDestroy(): void {
    remote.dispose().catch((error: Error) => hilog.error(0, 'SonyRemote', '%{public}s', error.message));
  }
}
