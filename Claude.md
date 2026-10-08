# CLAUDE.md（HarmonyOS NEXT Stage模型 · Dayer项目 约束文档）
> 用途：约束 Claude Code 生成合规鸿蒙 ArkTS / C++ 代码，**禁止输出前端React、Vue、Web、安卓风格代码**
> 项目信息：HarmonyOS NEXT，Stage应用模型，API 15，hvigor构建系统，ohpm包管理器
> 项目方向：上层Agent交互界面 + 端侧高性能推理模块（后续新增infer.hsp共享模块承载底层C/C++算子推理；当前初始化工程仅有entry主HAP模块）

## 一、基础全局规则（强制，所有代码生成必须遵守）
1. 本项目**不是网页、不是React/Vue、不是安卓应用**，所有UI必须使用ArkUI原生组件，不能写div/span/jsx，不能使用网页前端生命周期。
2. 构建命令：使用`hvigor`，包管理：`ohpm`；不要npm/yarn，不要webpack/vite。
3. 语言：页面层使用**ArkTS**；高性能推理算子、底层计算模块使用C/C++（NAPI桥接ArkTS与C++）。
4. 项目结构遵循标准Stage模型目录规范：`entry`主HAP模块，后续可新增`infer.hsp`共享模块，禁止随意自建非标准文件夹。
5. 严格锁定API版本：API15。**不允许使用API16及以上接口，不使用已废弃标记@deprecated的接口**。
    - 可执行检查：每个用到的系统接口，都要去 SDK 里对应的 `.d.ts` 核对 `@since` 标注，确认 ≤ 15 且未标 `@deprecated`。凭记忆写接口名等于没检查。
    - 注意 SDK 中存在「函数本身是 `@since 10`，但它的回调**参数类型**的成员是 `@since 21`」这类情况（实例：`NavDestination.onShown` 的回调参数 `VisibilityChangeReason`），**必须连带核对参数类型**，不能只看函数签名。
    - 编译通过**不等于**版本合规。已实测：用到超版本接口时，编译器只发警告、**仍然 `BUILD SUCCESSFUL`**。所以要 grep 构建输出里有没有这行，而不是只看退出码：
      ```
      ArkTS:WARN ... The 'xxx' API is supported since SDK version N. However, the current compatible SDK version is 5.0.3(15).
      ```
6. 代码风格：遵循鸿蒙ArkTS编码规范；类型必须显式标注，尽量开启严格类型校验，禁止大量any。
7. 所有配置文件后缀为`.json5`，不是json；注释在json5内合法。

## 二、ArkUI / Stage模型强制规范
1. 页面必须用`@Entry`装饰器标记；自定义UI组件用`@Component`。
    - `@Entry`页面才有页面生命周期：`onPageShow` / `onPageHide` / `onBackPress`
    - 普通`@Component`自定义组件**不能写页面生命周期回调**，仅可使用组件内`aboutToAppear` / `aboutToDisappear`
2. UIAbility是应用入口，对应应用进程实例；生命周期：`onCreate`、`onWindowStageCreate`、`onDestroy`，不要自行新增进程管理逻辑。
3. 线程强制规则：
    - **所有UI渲染代码必须在主线程执行**，严禁在主线程执行大循环、模型推理、重计算，会阻塞UI、触发闪退。
    - 耗时任务、大模型推理、矩阵运算，放到Worker子线程。
    - 跨线程传递对象：必须加`@Sendable`，普通对象无法跨Worker传递，不允许绕过该规则。
4. 状态装饰器规范，只能使用鸿蒙原生状态装饰器：`@State`、`@Prop`、`@Link`、`@Watch`，禁止前端Vue风格响应式写法。
5. 资源规范：
    - 图片、字符串、颜色、尺寸资源，**禁止硬编码写在代码里**，统一放在`resources`目录。
    - 读取资源使用`$r('sys.type.resource_id')`语法。
6. 页面路由：使用 `Navigation` + `NavPathStack` + `NavDestination`（SDK 推荐的方案），**不用 `router`**。
    - 持有 `NavPathStack` 并由 `Navigation(栈对象)` 接管，**不算**「自己写路由栈」——压栈/出栈/生命周期仍由 Navigation 管理，我们只持有引用。栈对象声明为**普通成员，不要加 `@State`**。
    - 路由表用 `@Builder`，经 `.navDestination(this.PageMap)` 注册，用 `if/else` 分发；每个分支**只能有一个根节点**，且**不能在这些自定义组件上挂任何属性或事件**，否则渲染为空白。
    - 跳转参数**必须传 class 实例，不能用对象字面量**（`arkts-no-untyped-obj-literals` 会拒绝）。路由表里 `param` 的声明类型用自定义类，**不能用 `unknown`**（`arkts-no-any-unknown` 会拒绝；官方 `navDestination` 文档明确允许替换为自定义类型），并保留 `instanceof` 运行时守卫。
    - 返回后的刷新**不要依赖 `onPop`**：系统返回手势调的是无参 `pop()`，不会触发带结果的回调，会静默漏刷新。改为把回调作为**组件构造参数**传给目标页，这样任何退出路径都能刷新。
    - `main_pages.json` 只注册 `@Entry` 页面；`NavDestination` 页面无需注册。
7. 自定义构建函数 `@Builder`：**需要随状态刷新的，一律写成无参数的**。
    - 官方《@Builder装饰器：自定义构建函数》原文：「调用@Builder装饰的函数默认按值传递。当传递的参数为状态变量时，**状态变量的改变不会引起@Builder方法内的UI刷新**。」只有「**只传一个**参数 + 以**对象字面量**传入」才算按引用传递 —— **传两个及以上参数必然退化成按值传递**。
    - 因此：组件内定义的 `@Builder` 默认**不带参数**，需要什么就在函数体内直接读 `this.*`（官方建议「通过 `this` 访问组件的状态变量，而不是通过参数传递」）。只有「文案/颜色永不变化」的入参（如字段标题）才允许带参。
    - 实测症状：`TaskDetailPage` 曾写成 `MetricColumn(label, value, valueColor)` 三参数，整块对照卡片**永久停在首帧**，同一屏自相矛盾 —— 卡片里第三栏显示「未记录计时」，紧邻其下由 `build()` 直接渲染的那行却显示「节省」。**编译器不报错、单测也测不出**，只能靠肉眼发现。
    - 附带约束：`@Builder` 内部**不允许修改参数值**。

## 三、权限、沙箱、配置文件规则
1. 应用运行在系统沙箱，默认无任何访问权限。
    - 需要相机、网络、文件、设备信息等能力，**必须在module.json5中声明对应权限**。
    - 区分system权限/用户动态授权，动态权限需要调用`requestPermissionsFromUser`主动申请。
2. 文件访问限制：不能随意读取手机全盘路径，仅允许访问：应用私有沙箱目录、用户通过文件选择器主动选中的文件。
3. 配置文件说明：
    - `app.json5`：全局应用配置，包名、版本号、应用签名相关。
    - `module.json5`：模块配置，abilities、ExtensionAbility、权限、元数据全部写在这里。
    新增UIAbility、ExtensionAbility，**必须同步在module.json5注册，否则系统无法识别**。
> ⚠️ 你不能直接修改app.json5 / module.json5 / BUILD.gn，修改前必须提醒我确认。

## 四、HAP / HSP模块分包规范（本项目架构）
1. `entry`模块：独立HAP，主应用入口，ArkUI界面、Agent交互逻辑。可独立安装。
2. `infer.hsp`：共享静态HSP模块，存放端侧推理C/C++代码、NAPI接口、通用工具函数；**HSP不能单独安装，只能被HAP引用。当前项目尚未创建，后续手动添加**。
3. 跨模块导入：HSP导出的类/函数必须显式export，entry模块import引入，不允许直接跨模块访问私有文件。

## 五、后台任务 & 端侧推理约束（本项目重点，Agent推理必看）
1. 应用切后台后，系统会冻结/杀掉进程。长时间大模型推理，**必须申请后台持续任务`BackgroundTaskManager`**。
2. 推理任务需要做分片、中断保存逻辑：后台被系统回收时，保存当前推理状态；切回前台可恢复。
3. 算力资源管控：不要无限制占用CPU，增加任务优先级控制，避免被系统判定耗电超限直接杀进程。

## 六、NAPI C/C++底层模块规范（高性能算子）
1. C/C++模块使用NAPI框架，用于ArkTS ↔ C++互操作；**禁止直接在ArkTS写重算力循环**。
2. C++代码放到`infer.hsp`模块的`cpp`目录。
3. NAPI接口注册逻辑写在`napi_module.cpp`，类型转换严格使用napi提供接口，内存手动管理，避免内存泄漏。
4. 多线程C++代码：不能直接操作ArkTS对象；回调回JS层必须通过napi异步回调。
5. 编译配置：`BUILD.gn`，库类型为共享库，依赖鸿蒙系统native API。

## 七、分布式超级终端（可选能力，按需生成）
1. 跨设备通信使用分布式软总线，通过`distributedData`、`want`完成设备拉起与数据同步。
2. 跨设备调用应用能力：目标应用模块必须配置`exported:true`，否则无法唤起。
3. 跨设备数据传输，要校验分布式权限，不允许无校验直接传输敏感数据。

## 八、代码输出、调试、日志规则
1. 日志打印统一使用`hilog`，不要console.log；hilog domain必须使用数字，搭配tag字符串和日志级别。
2. 代码增加必要异常捕获：推理报错、文件读取失败、权限拒绝、路由失败，都要有catch分支，不能裸写无保护调用。
3. 当你生成代码后，附带简要说明：代码作用、依赖模块、需要修改哪个json5配置、需要申请什么权限。
4. 编译报错修复：优先检查API版本、装饰器、线程Sendable、module注册项。

## 九、禁止清单（绝对不能生成）
❌ React / Vue / JSX / html / css / webpack / vite 相关代码
❌ Android、iOS平台API，安卓Intent（改用Want）
❌ 前端浏览器API（window, document）
❌ 无标注的全局any类型
❌ UI主线程执行长时间循环、模型推理
❌ 硬编码资源路径、图片字符串
❌ 绕过沙箱直接访问系统全盘文件
❌ 私自新增UIAbility而不在module.json5注册
❌ 使用API15之后的接口、废弃接口

## 十、MCP工具调用规则
你可以调用mcp-harmonyos工具执行：读取项目目录、hvigor构建、查看编译日志、hdc调试日志。
调用构建命令前，先告知用户，确认是否执行。
**不要自动执行hdc安装、真机部署操作，需要我确认。**