import Foundation

@main
struct TextEditPlannerSmoke {
    static func main() {
        let initial = "hello [old] world"
        var planner = TextEditPlanner(value: initial,
                                      selection: (initial as NSString).range(of: "[old]"))
        var plan = planner.plan(current: initial, nextTranscript: "你", selection: nil)
        precondition(plan.valueAfterEdit == "hello 你 world")
        planner.commit(plan)

        plan = planner.plan(current: "hello 你 world\n", nextTranscript: "你好", selection: nil)
        precondition(plan.valueAfterEdit == "hello 你好 world\n")
        planner.commit(plan)

        plan = planner.plan(current: "Intro: hello 你好 world\n",
                            nextTranscript: "你好啊", selection: nil)
        precondition(plan.valueAfterEdit == "Intro: hello 你好啊 world\n")
        planner.commit(plan)

        plan = planner.plan(current: "Intro: hello 你，好啊 world\n",
                            nextTranscript: "你好啊！", selection: nil)
        precondition(plan.valueAfterEdit == "Intro: hello 你好啊！ world\n")
        planner.commit(plan)

        var ambiguous = TextEditPlanner(value: "A bar B", selection: NSRange(location: 2, length: 3))
        plan = ambiguous.plan(current: "A bar B", nextTranscript: "bar", selection: nil)
        ambiguous.commit(plan)
        plan = ambiguous.plan(current: "X bar bar Y", nextTranscript: "bark",
                              selection: NSRange(location: 11, length: 0))
        precondition(plan.appendOnly)
        precondition(plan.valueAfterEdit == "X bar bar Yk")
        ambiguous.commit(plan)
        plan = ambiguous.plan(current: plan.valueAfterEdit, nextTranscript: "barking", selection: nil)
        precondition(plan.valueAfterEdit == "X bar bar Yking")

        print("PASS: 流式替换保留外部编辑，无法定位时继续追加")
    }
}
