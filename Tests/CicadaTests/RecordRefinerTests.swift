import Foundation
import Testing
@testable import Cicada

@Suite struct RecordRefinerTests {
    private func run(_ text: String, _ start: Double, _ end: Double) -> Recognition.Run { .init(text: text, start: start, end: end) }

    @Test func lineTakesTheRecordsWords() {
        var r = RecordRefiner()
        #expect(r.emitted(id: 1, start: 0, end: 3, text: "今天周你过一下后才角色和权限。").isEmpty)
        #expect(r.emitted(id: 2, start: 3.2, end: 6, text: "就是这个功能").isEmpty)
        let out = r.heard([run("今天就要过一下后台角色和权限。", 0.1, 2.9)], through: 3.1)
        #expect(out.map(\.id) == [1])
        #expect(out.first?.text == "今天就要过一下后台角色和权限。")
    }

    @Test func textDecidesTheEnd() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 4, text: "每天凌晨跑一次回收完给管理员发一个通。")
        _ = r.emitted(id: 2, start: 4.2, end: 6, text: "好到今天就要下周二我们再约一次。")
        let out = r.heard([run("每天凌晨跑一次回收完给管理员发一个通知。好那今天就先这样下周二我们再约一下进度。", 0.1, 5.9)], through: 6.1)
        #expect(out.map(\.text) == ["每天凌晨跑一次回收完给管理员发一个通知。"])
        #expect(r.finish().map(\.text) == ["好那今天就先这样下周二我们再约一下进度。"])
    }

    @Test func splitWordGoesWhole() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 2, text: "每天跑一次回")
        _ = r.emitted(id: 2, start: 2, end: 4, text: "收完发通知。")
        _ = r.emitted(id: 3, start: 4.5, end: 6, text: "好的。")
        let out = r.heard([run("每天跑一次回收完发通知。", 0.2, 3.9)], through: 4.2)
        #expect(out.count == 2)
        #expect(out.map(\.text).joined() == "每天跑一次回收完发通知。")
    }

    @Test func connectiveStaysWhole() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 4, text: "实际面积会比这个还要大一些所")
        _ = r.emitted(id: 2, start: 4, end: 7, text: "以很多人设想的这个概率不是很大")
        _ = r.emitted(id: 3, start: 7.5, end: 9, text: "好的。")
        let out = r.heard([run("实际面积会比这个还要大一些所以很多人设想的这个概率不是很大", 0.1, 6.9)], through: 7.2)
        #expect(out.map(\.text) == ["实际面积会比这个还要大一些", "所以很多人设想的这个概率不是很大"])
    }

    @Test func lostWordsAreKept() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 2, text: "那我说一下吧，")
        _ = r.emitted(id: 2, start: 3, end: 5, text: "才说的意思")
        _ = r.emitted(id: 3, start: 6, end: 8, text: "对。")
        let out = r.heard([run("那我说一下吧，我理解刚才说的意思", 0.1, 4.9)], through: 5.2)
        #expect(out.map(\.text).joined() == "那我说一下吧，我理解刚才说的意思")
        #expect(out.last?.text.hasSuffix("才说的意思") == true)
    }

    @Test func lastLineWaits() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 2, text: "好的。")
        #expect(r.heard([run("好的。", 0.2, 1.9)], through: 2.1).isEmpty)
        #expect(r.heard([run("下周二", 4.5, 5.5)]).map(\.text) == ["好的。"])
    }

    @Test func recordRunsAhead() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 2, text: "先接企业微信吧。")
        let out = r.heard([run("先接企业微信吧。飞书下个迭代再说。", 0.1, 6)], through: 6.2)
        #expect(out.map(\.text) == ["先接企业微信吧。"])
        _ = r.emitted(id: 2, start: 2.5, end: 6, text: "飞书下个节日再说。")
        #expect(r.finish().map(\.text) == ["飞书下个迭代再说。"])
    }

    @Test func lineEndsAtNearbyPunctuation() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 3, text: "我理解刚才说的意思就是给用户赋予某个角色，然后这个")
        _ = r.emitted(id: 2, start: 3, end: 5, text: "角色带着一组权限。")
        _ = r.emitted(id: 3, start: 6, end: 7, text: "对。")
        let out = r.heard([run("我理解刚才说的意思就是给用户赋予某个角色，然后这个角色带着一组权限。", 0.1, 4.9)], through: 5.2)
        #expect(out.map(\.text) == ["我理解刚才说的意思就是给用户赋予某个角色，", "然后这个角色带着一组权限。"])
    }

    @Test func lineEndsBetweenWords() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 3, text: "他这个管理员可能就是因为他权限比较大了审")
        _ = r.emitted(id: 2, start: 3, end: 5, text: "计日志一定要记下来")
        _ = r.emitted(id: 3, start: 6, end: 7, text: "对")
        let out = r.heard([run("他这个管理员可能就是因为他权限比较大了审计日志一定要记下来", 0.1, 4.9)], through: 5.2)
        #expect(out.first?.text.hasSuffix("审") == false)
        #expect(out.map(\.text).joined() == "他这个管理员可能就是因为他权限比较大了审计日志一定要记下来")
    }

    @Test func wordsStayWithTheirSpeaker() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 4, text: "Uh, I think we can ship March 3rd if design signs off by Friday.")
        _ = r.emitted(id: 2, start: 4.2, end: 5.5, text: "Great, let's lock that in.")
        var out = r.heard([run(" Uh, I think we can ship March 3rd if design signs off by Friday.", 0.1, 3.9)], through: 4.1)
        out += r.heard([run(" Great.", 4.2, 4.6)])
        out += r.heard([run(" let's lock that in", 4.7, 5.4)])
        _ = r.emitted(id: 3, start: 9.5, end: 11, text: "Okay, so where are we on the launch?")
        out += r.heard([run(" Okay, so where are we on the launch?", 9.5, 11)], through: 11.2)
        out += r.finish()
        #expect(out.map(\.text).map { $0.trimmingCharacters(in: .whitespaces) } == [
            "Uh, I think we can ship March 3rd if design signs off by Friday.",
            "Great. let's lock that in",
            "Okay, so where are we on the launch?",
        ])
        var one = RecordRefiner()
        _ = one.emitted(id: 1, start: 0, end: 4, text: "Uh, I think we can ship March 3rd if design signs off by Friday.")
        _ = one.emitted(id: 2, start: 4.2, end: 5.5, text: "Great, let's lock that in.")
        _ = one.emitted(id: 3, start: 9.5, end: 11, text: "Okay, so where are we on the launch?")
        let both = one.heard([run(" Uh, I think we can ship March 3rd if design signs off by Friday. Great. let's lock that in", 0.1, 5.4)], through: 5.6)
        #expect(both.map { $0.text.trimmingCharacters(in: .whitespaces) } == [
            "Uh, I think we can ship March 3rd if design signs off by Friday.", "Great. let's lock that in",
        ])
    }

    @Test func closedLineLeavesTheRestForTheNext() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 4, text: "Uh, I think we can ship March 3rd if design signs off by Friday.")
        var out = r.heard([run(" Uh, I think we can ship March 3rd if design signs off by Friday.", 0.1, 3.9)], through: 4.1)
        out += r.heard([run(" Great.", 4.2, 4.6)])
        out += r.heard([run(" let's lock that in", 4.7, 5.4)], through: 5.6)
        out += r.emitted(id: 2, start: 4.7, end: 5.4, text: "Let's lock that in")
        out += r.finish()
        #expect(out.map { $0.text.trimmingCharacters(in: .whitespaces) } == [
            "Uh, I think we can ship March 3rd if design signs off by Friday.", "Great. let's lock that in",
        ])
    }

    @Test func closedLineKeepsItsMark() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 0.5, text: "Great.")
        _ = r.emitted(id: 2, start: 0.7, end: 1.5, text: "lock that in.")
        _ = r.emitted(id: 3, start: 6, end: 7, text: "Okay, so where are we on the launch?")
        var out = r.heard([run(" Great.", 0, 0.5)])
        out += r.heard([run(" Let's lock that in", 0.6, 1.5)], through: 1.7)
        #expect(out.first?.text.trimmingCharacters(in: .whitespaces) == "Great.")
    }

    @Test func finishSettlesTheRest() {
        var r = RecordRefiner()
        _ = r.emitted(id: 1, start: 0, end: 2, text: "好的。")
        _ = r.emitted(id: 2, start: 10, end: 12, text: "嗯。")
        let out = r.finish()
        #expect(out.map(\.id) == [1, 2])
        #expect(out.map(\.text) == ["", ""])
    }
}
