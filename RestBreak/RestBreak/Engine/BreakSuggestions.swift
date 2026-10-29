import Foundation

/// 中文休息建议库。随机挑一条，并保证同一种休息不会连续两次出现同一句。
struct BreakSuggestions {
    /// 微休息：护眼、呼吸、坐姿
    static let micro: [String] = [
        "看向 6 米外的远处，保持 20 秒",
        "闭上眼睛，慢慢数到 20",
        "用力眨眼 10 次，让眼睛重新湿润",
        "眼球缓慢画圈：顺时针 5 圈，逆时针 5 圈",
        "搓热双手，轻轻捂住眼睛",
        "深吸气 4 秒，屏住 4 秒，缓缓呼气 6 秒",
        "做三次腹式呼吸，感受肚子起伏",
        "放下肩膀，让它们离耳朵远一点",
        "挺直后背，双脚平放在地面",
        "轻轻把头向左、向右各侧倾 5 秒",
        "收一收下巴，让脖子回到身体正上方",
        "松开紧咬的牙关，放松面部肌肉",
        "看看窗外的绿色植物或天空",
        "十指交叉向前推，伸展手腕和手臂",
        "转动手腕，各方向 5 圈",
    ]

    /// 长休息：起身走动、喝水、拉伸
    static let long: [String] = [
        "站起来，去倒一杯水慢慢喝完",
        "离开座位，走动几分钟",
        "到窗边或阳台，看看远处，呼吸新鲜空气",
        "双手举过头顶，踮脚向上拉伸全身",
        "扶着桌边做 10 个靠墙俯卧撑",
        "原地慢慢做 10 个深蹲",
        "双手在背后交握，挺胸打开肩膀",
        "左右转动腰部，各保持 10 秒",
        "单手扶墙，拉伸大腿前侧，左右各 20 秒",
        "活动脚踝，踮脚尖再落下 15 次",
        "去趟洗手间，顺便洗把脸",
        "整理一下桌面，扔掉用不到的东西",
        "做一遍眼保健操",
        "站着打一套八段锦的「两手托天理三焦」",
        "给自己泡杯茶，看看水汽慢慢升起",
    ]

    /// 记录每种休息上一次用过的建议
    private var lastShown: [BreakKind: String] = [:]

    mutating func next(for kind: BreakKind) -> String {
        let pool = kind == .micro ? Self.micro : Self.long
        let candidates = pool.filter { $0 != lastShown[kind] }
        let pick = candidates.randomElement() ?? pool[0]
        lastShown[kind] = pick
        return pick
    }
}
