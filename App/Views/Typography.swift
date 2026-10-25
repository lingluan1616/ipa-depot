import SwiftUI

/// 品牌字体：阿里妈妈数黑体（只有 Bold 一款）。只用于标题与数字：
/// 页面/弹窗大标题、App 名、版本号、下载进度的数字与大小、记录页数字。
/// 正文、说明、按钮、表单一律用系统字体。字体缺失或缺字时由系统自动回退到系统字体。
enum BrandFont {
    static let postScriptName = "AlimamaShuHeiTi-Bold"

    /// 弹窗 / 页面大标题（对应 .title2）。
    static var title: Font { .custom(postScriptName, size: 22, relativeTo: .title2) }
    /// 详情页头部的 App 名（对应 .title2）。
    static var heroName: Font { .custom(postScriptName, size: 20, relativeTo: .title2) }
    /// 列表里的 App 名（对应 .headline）。
    static var name: Font { .custom(postScriptName, size: 14, relativeTo: .headline) }
    /// 版本号（对应 .body）。
    static var version: Font { .custom(postScriptName, size: 13, relativeTo: .body) }
    /// 列表里次要的数字（版本号旁、记录页）（对应 .callout）。
    static var number: Font { .custom(postScriptName, size: 12, relativeTo: .callout) }
    /// 进度、大小、速度等小号数字（对应 .caption）。
    static var smallNumber: Font { .custom(postScriptName, size: 11, relativeTo: .caption) }
}
