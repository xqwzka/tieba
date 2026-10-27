import Foundation

// 手写 protobuf 编解码（无第三方依赖），只覆盖发帖用到的字段。
// 字段编号来源：TiebaLite 的 AddPostRequestData.proto、CommonRequest.proto、Error.proto。
// 发帖走 protobuf 接口的原因：JSON 表单接口 /c/c/post/add 现在服务端收了也不落库
//（有返回、无报错、官方 App 也看不到），TiebaLite 现行发帖同样走 protobuf。
enum TiebaProtobuf {
    struct Writer {
        var bytes = Data()

        mutating func tag(_ field: Int, wire: Int) { varint(UInt64((field << 3) | wire)) }

        mutating func varint(_ value: UInt64) {
            var v = value
            repeat {
                var b = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { b |= 0x80 }
                bytes.append(b)
            } while v != 0
        }

        mutating func stringField(_ field: Int, _ value: String) {
            tag(field, wire: 2)
            let d = Data(value.utf8)
            varint(UInt64(d.count))
            bytes.append(d)
        }

        mutating func bytesField(_ field: Int, _ data: Data) {
            tag(field, wire: 2)
            varint(UInt64(data.count))
            bytes.append(data)
        }

        mutating func intField(_ field: Int, _ value: Int) {
            tag(field, wire: 0)
            varint(UInt64(bitPattern: Int64(value)))
        }

        mutating func int64Field(_ field: Int, _ value: Int64) {
            tag(field, wire: 0)
            varint(UInt64(bitPattern: value))
        }
    }

    // CommonRequest（V12_POST 精简版）：只带身份与版本字段，
    // _client_id、cuid、imei、android_id、device_score 等设备指纹一律不发（开发文档红线）。
    static func commonRequest(bduss: String, stoken: String?, tbs: String) -> Data {
        var w = Writer()
        w.intField(1, 2) // _client_type
        w.stringField(2, "12.35.1.0") // _client_version（TiebaLite TIEBA_V12_POST）
        w.int64Field(8, Int64(Date().timeIntervalSince1970 * 1000)) // _timestamp
        w.stringField(10, bduss) // BDUSS
        w.stringField(11, tbs) // tbs
        if let stoken, !stoken.isEmpty { w.stringField(30, stoken) } // stoken
        return w.bytes
    }

    // AddPostRequestData：postId 为空 = 楼层回复；非空 = 楼中楼回复。
    static func addPostRequest(
        bduss: String, stoken: String?, tbs: String,
        fid: String, kw: String, tid: String, content: String,
        postId: String?, replyUid: String?
    ) -> Data {
        var d = Writer()
        d.bytesField(1, commonRequest(bduss: bduss, stoken: stoken, tbs: tbs)) // common
        d.stringField(6, "1") // anonymous（TiebaLite 发帖固定为 1）
        d.stringField(7, "0") // can_no_forum
        d.stringField(8, "0") // is_feedback
        d.stringField(9, "0") // takephoto_num
        d.stringField(10, "0") // entrance_type
        d.stringField(16, "12") // vcode_tag
        d.stringField(18, "1") // new_vcode
        d.stringField(19, content)
        d.stringField(26, fid)
        d.stringField(30, kw)
        d.stringField(45, tid)
        d.stringField(51, "0") // is_ad
        d.stringField(60, "0") // is_pictxt
        d.intField(64, 0) // show_custom_figure
        d.intField(67, 0) // is_show_bless
        if let postId, !postId.isEmpty {
            d.stringField(46, postId) // quote_id
            d.stringField(49, postId) // repostid
            d.stringField(55, "0") // post_from
            if let replyUid, !replyUid.isEmpty { d.stringField(20, replyUid) } // reply_uid
        } else {
            d.stringField(28, "") // v_fid
            d.stringField(29, "") // v_fname
            d.stringField(31, "0") // is_barrage
            d.stringField(32, "0") // barrage_time
            d.stringField(47, "0") // is_twzhibo_thread
            d.stringField(48, "0") // floor_num
            d.stringField(52, "0") // is_addition
            d.stringField(53, "0") // is_giftpost
            d.stringField(55, "13") // post_from
        }
        var req = Writer()
        req.bytesField(1, d.bytes) // AddPostRequest.data
        return req.bytes
    }

    // 解析 AddPostResponse：只读 field 1（Error）：1=error_code，2=error_msg，3=user_msg。
    // 无法解析返回 nil（调用方不得再当成功处理，这是之前“静默失败”的根因之一）。
    static func parseAddPostError(_ data: Data) -> (Int, String)? {
        func readVarint(_ data: Data, _ i: inout Data.Index) -> UInt64? {
            var result: UInt64 = 0
            var shift = 0
            while i < data.endIndex {
                let b = data[i]
                i = data.index(after: i)
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        var i = data.startIndex
        while i < data.endIndex {
            guard let key = readVarint(data, &i) else { return nil }
            let field = Int(key >> 3)
            let wire = Int(key & 7)
            switch wire {
            case 0:
                guard readVarint(data, &i) != nil else { return nil }
            case 2:
                guard let len = readVarint(data, &i), i + Int(len) <= data.endIndex else { return nil }
                let slice = data[i ..< i + Int(len)]
                i = i + Int(len)
                if field == 1 {
                    var code = 0
                    var msg = ""
                    var j = slice.startIndex
                    while j < slice.endIndex {
                        guard let k2 = readVarint(slice, &j) else { return nil }
                        let f2 = Int(k2 >> 3)
                        let w2 = Int(k2 & 7)
                        if w2 == 0 {
                            guard let v = readVarint(slice, &j) else { return nil }
                            if f2 == 1 { code = Int(v) }
                        } else if w2 == 2 {
                            guard let l2 = readVarint(slice, &j), j + Int(l2) <= slice.endIndex else { return nil }
                            let s = String(data: slice[j ..< j + Int(l2)], encoding: .utf8) ?? ""
                            if f2 == 2 || f2 == 3, !s.isEmpty { msg = s }
                            j = j + Int(l2)
                        } else {
                            return nil
                        }
                    }
                    return (code, msg)
                }
            default:
                return nil
            }
        }
        return nil
    }

    // multipart 体：与 TiebaLite 的 buildProtobufRequestBody 一致，
    // STOKEN 文本段 + data 文件段（filename=file），boundary 固定。
    static func multipartBody(stoken: String?, protobuf: Data) -> (Data, String) {
        let boundary = "--------7da3d81520810*"
        var body = Data()
        func part(_ text: String) { body.append(Data(text.utf8)) }
        if let stoken, !stoken.isEmpty {
            part("--\(boundary)\r\nContent-Disposition: form-data; name=\"STOKEN\"\r\n\r\n\(stoken)\r\n")
        }
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n")
        body.append(protobuf)
        part("\r\n--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}
