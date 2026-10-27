# 贴吧（第三方客户端）

iOS 17、SwiftUI、无第三方依赖、XcodeGen 构建的独立贴吧客户端。
只做四件事：扫码登录、阅读、发帖、回复。不做直播、视频、商城、会员等。

## 功能

- 扫码登录：原生二维码 + 备用网页扫码
- 阅读：吧列表（本地保存）、帖子列表分页、楼层列表分页、楼中楼分页、只看楼主（本地过滤）
- 发帖：发主题（标题 + 内容）
- 回帖：帖子底部回帖、每楼的楼中楼回复
- 未登录也能阅读；发帖、回复按钮在未登录时提示先登录
- 所有网络错误、服务端错误都在界面上以中文显示，不静默失败

## 登录说明

- 主路径是原生扫码：App 向百度 passport 请求二维码，展示后用百度 App / 贴吧 App 扫码并确认，App 每 2 秒轮询一次，最多 120 次（约 4 分钟），轮询返回里一旦出现 BDUSS 即完成登录。
- 备用入口在登录页底部：「网页扫码（备用）」，打开百度 passport 登录页（该页本身有扫码），App 每 2 秒检查一次网页 Cookie，拿到 BDUSS 即完成登录。
- BDUSS / STOKEN 只保存在本机 iOS Keychain，不写 UserDefaults、不打日志、不经过任何自有服务器。所有贴吧请求都直连 `c.tieba.baidu.com`（发帖凭证走 `tieba.baidu.com/dc/common/tbs`）。
- 退出登录：首页右上角「退出登录」，即删除 Keychain 里的 BDUSS 和 STOKEN。

## 构建

```sh
xcodegen generate
xcodebuild -project Tieba.xcodeproj -scheme Tieba -sdk iphoneos \
  -configuration Release CODE_SIGNING_ALLOWED=NO build
```

也可以用 `.github/workflows/build-ipa.yml`：推送到 main 分支后在 macOS runner 上生成未签名 IPA，产物 `Tieba-unsigned.ipa` 会发布到 `builds` 分支（附 `ipa.sha256`、`ipa_part_*` 分片和 `ipa_parts.count`），侧载安装。

## 已知未真机验证点

以下均未在本机验证（本机无 Xcode、无真机），按可能性排序，真机联调时先查这几处：

1. **原生扫码轮询**：`passport.baidu.com/channel/unicast?channel_id=<sign>` 返回里是否真的直接带有 BDUSS（JSON 或 Set-Cookie）。如果扫码确认后轮询一直拿不到 BDUSS，二维码会在约 4 分钟后过期，届时请先用底部的「网页扫码（备用）」入口登录——它直接读网页 Cookie，不依赖轮询返回格式。
2. **发帖签名与 tbs**：`c/c/thread/add`、`c/c/post/add`、`c/c/comment/add` 的签名算法（参数按 key 排序拼 `key=value` 后加 `tiebaclient!!!` 再 MD5）与 `dc/common/tbs` 返回的 tbs 是否仍被当前服务端接受。签名或 tbs 一变，发帖会直接报服务端原错，界面会原样显示。
3. **帖子/楼层字段名**：`c/f/frs/page`、`c/f/pb/page`、`c/f/pb/floor` 的 `thread_list`、`post_list`、`subpost_list` 结构与作者、时间、内容片段（type 0 文字、type 3 图片 `origin_src`）字段是否与代码假设一致。解析已做防御处理（缺失字段用默认值，不崩溃），但字段名一旦改名，列表可能出现空白或缺内容。
4. **风控**：新号、高频发帖、敏感词可能触发验证码、删帖或封号。发帖失败时界面显示的是服务端原错，按原错处理，不要反复重试。
5. **只看楼主**：本地按作者名与帖子作者名相等过滤，若服务端返回的作者名格式不一致（如昵称与用户名混用），过滤可能漏楼层。
