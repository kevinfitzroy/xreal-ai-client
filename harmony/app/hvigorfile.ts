import { appTasks } from '@ohos/hvigor-ohos-plugin';

// 纯 HarmonyOS NEXT 工程用 @ohos/hvigor-ohos-plugin(appTasks/hapTasks)。
// 不要用 ArkUI-X 跨平台插件(那是跨 Android/iOS 工程的)。本项目各端各自原生,不跨平台。
export default {
  system: appTasks,
  plugins: []
};
