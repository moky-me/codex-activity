import Foundation
import ActivityCore

let started = Date()
do {
    let repository = ActivityRepository()
    if CommandLine.arguments.contains("--audit") {
        _ = try repository.load(period:.unlimited)
        Thread.sleep(forTimeInterval:3)
        let all=try repository.load(period:.unlimited)
        let recent=try repository.load()
        for card in all.cards where [.running,.paused,.unknown,.needsInput].contains(card.state) {
            print("\(card.threadID) | \(card.state.rawValue) | \(ActivityPolicy.age(card.updatedAt)) | \(card.title.prefix(65))")
        }
        print("TOTAL \(all.cards.count), 4H \(recent.cards.count), RUNNING \(all.cards.filter { $0.state == .running }.count)")
        exit(0)
    }
    if CommandLine.arguments.contains("--periods") {
        let now=Date()
        for period in ActivityPeriod.allCases {
            let start=Date()
            let result=try repository.load(now:now,period:period)
            print("\(period.label): \(result.cards.count) cards, \(result.cards.filter { $0.state == .needsInput }.count) pending, \(String(format:"%.3fs",Date().timeIntervalSince(start)))")
        }
        exit(0)
    }
    let snapshot = try repository.load()
    print("Cards: \(snapshot.cards.count)")
    for state in ActivityState.allCases {
        print("\(state.rawValue): \(snapshot.cards.filter { $0.state == state }.count)")
    }
    print("Notice: \(snapshot.notice ?? "none")")
    print(String(format:"Initial read: %.3fs",Date().timeIntervalSince(started)))
    let warm = Date()
    let next = try repository.load()
    print(String(format:"Incremental read: %.3fs",Date().timeIntervalSince(warm)))
    print("Valid links: \(next.cards.allSatisfy { $0.isChatGPTHosted ? $0.url == nil : $0.url?.scheme == "codex" })")
    if CommandLine.arguments.contains("--titles") {
        for card in next.cards { print("\(card.state.label) | \(card.title) | \(card.project) | \(card.summary)") }
    }
} catch {
    fputs("Read failed: \(error.localizedDescription)\n",stderr); exit(1)
}
