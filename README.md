# 贴吧（第三方客户端，重编版）

> 免责声明：本项目非官方、非商业、仅供个人学习与开源交流，与百度无关。
> 百度没有公开 API，接口来自对官方客户端/网页的分析，随时可能变更或失效；
> 账号可能被风控限制。不要用本项目做商业化、批量/高频请求、绕过会员或广告。
> 应用显示名仍为“贴吧”时存在商标误导风险，正式发布前建议改名并去掉百度/贴吧 Logo。

iOS 17、SwiftUI、无第三方依赖、XcodeGen 构建。只做四件事：扫码登录、阅读、发帖、回复。
不做：签到、消息、历史、会员、广告屏蔽（上一版演示原型里的签到/消息/历史是写死数据，
不是真接口，本版不包含）；不自建密码框，不粘贴 BDUSS。

## 接口验证表（2026-10-27）

| 接口 | 状态 | 依据 |
| --- | --- | --- |
| 帖子列表 frs | 通过 | 带签名请求返回 thread_list，作者靠 user_list 按 author_id 映射（name_show） |
| 帖子详情 pb（客户端） | 通过（匿名只读） | 2026-10-27 实测：根因是之前发 tid 参数服务端不认；改 kz=帖子 id 后匿名返回 error_code 0、post_list 15 条，首楼作者经 user_list 映射为“萌酱”，与网页版一致；登录后真机仍待确认 |
| 网页版帖子页 | 通过 | 官方页面能看到楼层、作者、头像、回复数 |
| 关注的吧 forum/like | 匿名不通过 | 匿名返回空，无吧名；登录后未验证通过，另有网页版我的吧导入兜底 |
| 网页扫码登录 | 通过（真机） | 用户已用网页扫码登录成功 |
| 原生扫码登录 | 未验证通过 | 初版真机报解析失败，后续修复未确认 |
| 发帖/回复/tbs | 未验证通过 | 需要登录态，未在真机验证通过 |
| 楼中楼 pb/floor | 参数已按 TiebaLite 改为 kz + POST | 之前 tid + GET 未验证通过；改后未在真机验证通过 |

主路径原则：只把通过的接口放主路径。详情主路径是：先试客户端接口，
失败自动切网页版详情；关注主路径是：客户端接口 + 网页版导入兜底。

## 结构（三层）

- UI 层：`HomeView`、`ThreadListView`、`ThreadDetailView`、`ComposeView`、`LoginView` 等，只用自有模型。
- 数据模型层：`Models.swift`。
- 接口适配层：`TiebaClient.swift`，所有请求、签名、解析只在这里。

## 安全红线

- 登录只用 WKWebView 官方登录页，凭证只存本机 Keychain，不上传服务器、不打日志。
- 不伪造设备指纹，不带 cuid；标准 UA。
- 验证码一律交给用户手动处理，不自动识别或绕过。
- 发帖/回复提交间隔不少于 5 秒；列表、详情按页缓存 60 秒。

## 构建

```sh
xcodegen generate
xcodebuild -project Tieba.xcodeproj -scheme Tieba -sdk iphoneos \
  -configuration Release CODE_SIGNING_ALLOWED=NO build
```

推送到 main 后 GitHub Actions 编未签名 IPA，发布到 `builds` 分支。
